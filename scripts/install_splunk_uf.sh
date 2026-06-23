#!/usr/bin/env bash
# install_splunk_uf.sh — Splunk Universal Forwarder shipping DNS-collector's
# NIOS-style query/response lines into the indexer's existing splunktcp (S2S)
# input — the same :8005 input the Infoblox Data Connector uses.
#
# WHY A UF: the indexer's 8005 is a Splunk-to-Splunk forwarder input. It
# accepts any TCP connection (nc -zv "succeeds") but silently discards raw
# text/syslog — only the S2S protocol indexes. DNS-collector has no S2S
# output, so it writes NIOS-lookalike lines to a file (NIOS_LOG_PATH in
# install_dnscollector_receiver.sh) and this UF monitors + forwards them.
# Verified end-to-end 2026-06-12 against 172.25.15.215:8005 (S2S v3 handshake,
# queue drained).
#
# Tunables (env):
#   SPLUNK_IDX_ADDR  indexer host:port S2S input   (default 172.25.15.215:8005)
#   NIOS_LOG_PATH    file DNS-collector writes      (default /var/log/dnscollector/nios.log)
#   SPLUNK_INDEX     target index                   (default mi_dhcp)
#   SPLUNK_SOURCETYPE sourcetype                    (default infoblox:dns)
#   UF_VERSION / UF_BUILD  tarball coordinates      (default 9.2.2/d76edf6f0a15)
#
# RHEL 7.9 NOTE: UF 9.2.x is the LAST release line that runs on kernel 3.x
# (RHEL 7) — kernel 3.x is deprecated in 9.2 and removed in 9.3+. Do not bump
# UF_VERSION past 9.2.x for the 172.25.15.234 POC box; the script refuses to
# install >=9.3 on a 3.x kernel.
#
# Usage: sudo -E ./install_splunk_uf.sh     (RHEL 7+ x86_64; static deps only)
set -euo pipefail

# NIOS_LOG_PATH = DNS-collector's lines (source=dnstap:dnscollector).
# VECTOR_NIOS_LOG_PATH = Vector's lines (source=dnstap:vector), optional.
# Use `-` not `:-` so an explicitly-empty value disables that monitor
# (e.g. Vector-only: NIOS_LOG_PATH="" VECTOR_NIOS_LOG_PATH=/var/log/dnstap/nios.log).
SPLUNK_IDX_ADDR="${SPLUNK_IDX_ADDR:-172.25.15.215:8005}"
NIOS_LOG_PATH="${NIOS_LOG_PATH-/var/log/dnscollector/nios.log}"
VECTOR_NIOS_LOG_PATH="${VECTOR_NIOS_LOG_PATH-}"
SPLUNK_INDEX="${SPLUNK_INDEX:-mi_dhcp}"
SPLUNK_SOURCETYPE="${SPLUNK_SOURCETYPE:-infoblox:dns}"
# Optional system-health monitor (scripts/poc_health_snmp.py writes this file).
# Empty = disabled. Lands in the same index, distinguished by source/sourcetype.
HEALTH_LOG_PATH="${HEALTH_LOG_PATH-}"
HEALTH_SOURCETYPE="${HEALTH_SOURCETYPE:-infoblox:health}"
HEALTH_SOURCE="${HEALTH_SOURCE:-infoblox:health}"
UF_VERSION="${UF_VERSION:-9.2.2}"
UF_BUILD="${UF_BUILD:-d76edf6f0a15}"
UF_HOME=/opt/splunkforwarder

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)."; exit 1; }

# kernel 3.x (RHEL 7) supports UF 9.2.x at most — refuse a build that won't run.
KERNEL_MAJOR="$(uname -r | cut -d. -f1)"
UF_MINOR="$(echo "$UF_VERSION" | cut -d. -f1-2)"
if [ "$KERNEL_MAJOR" -lt 4 ]; then
  case "$UF_MINOR" in
    9.0|9.1|9.2) : ;;
    *) echo "ERROR: kernel $(uname -r) (RHEL 7?) supports UF 9.2.x at most; got ${UF_VERSION}."
       echo "       Set UF_VERSION=9.2.2 UF_BUILD=d76edf6f0a15 (or another 9.2.x build)."
       exit 1 ;;
  esac
fi

echo "==> Installing Splunk Universal Forwarder ${UF_VERSION}"
if [ -x "$UF_HOME/bin/splunk" ]; then
  echo "    already installed at $UF_HOME, skipping download"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  URL="https://download.splunk.com/products/universalforwarder/releases/${UF_VERSION}/linux/splunkforwarder-${UF_VERSION}-${UF_BUILD}-Linux-x86_64.tgz"
  echo "    downloading $URL"
  case "${DNSTAP_INSECURE_DOWNLOADS:-}" in
    1|true|yes|on|TRUE|YES|ON) curl -fSL --retry 3 -k -o "$TMP/uf.tgz" "$URL" ;;
    *) curl -fSL --retry 3 -o "$TMP/uf.tgz" "$URL" || {
         echo "    ! verified download failed; retrying with -k"; curl -fSL --retry 3 -k -o "$TMP/uf.tgz" "$URL"; } ;;
  esac
  tar -xzf "$TMP/uf.tgz" -C /opt
fi

echo "==> User"
id splunkfwd >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin splunkfwd

[ -n "$NIOS_LOG_PATH" ] || [ -n "$VECTOR_NIOS_LOG_PATH" ] || {
  echo "ERROR: set NIOS_LOG_PATH and/or VECTOR_NIOS_LOG_PATH (nothing to monitor)."; exit 1; }

echo "==> Config (etc/system/local)"
install -d "$UF_HOME/etc/system/local"

# Detect a SHARED / managed forwarder: one that already forwards somewhere
# (apps define a [tcpout] group, or it is deployment-server managed). On such
# a box we must NOT hijack default routing or rename it — we only ADD our
# indexer as a named group and route ONLY the dnstap monitors to it via
# _TCP_ROUTING, leaving the box's existing forwarding untouched.
MANAGED=0
if grep -rslq '^\[tcpout' "$UF_HOME/etc/apps" 2>/dev/null \
   || [ -f "$UF_HOME/etc/system/local/deploymentclient.conf" ]; then
  MANAGED=1
fi
ROUTE=""   # per-monitor _TCP_ROUTING (set on managed boxes; harmless to always set)

# Back up anything we are about to replace (timestamped, kept on the box).
TS="$(date +%Y%m%d-%H%M%S)"
for f in outputs.conf inputs.conf server.conf; do
  [ -f "$UF_HOME/etc/system/local/$f" ] && \
    cp -p "$UF_HOME/etc/system/local/$f" "$UF_HOME/etc/system/local/$f.dnstap-bak.$TS"
done

# outputs.conf — always define our named group; only claim defaultGroup on a
# dedicated UF. On a managed UF leave defaultGroup alone (apps own it).
{
  echo "[tcpout:mi_indexer]"
  echo "server = ${SPLUNK_IDX_ADDR}"
  echo "useACK = false"
  if [ "$MANAGED" = "0" ]; then
    printf '\n[tcpout]\ndefaultGroup = mi_indexer\n'
  fi
} > "$UF_HOME/etc/system/local/outputs.conf"
if [ "$MANAGED" = "1" ]; then
  echo "    ! managed/shared forwarder detected — NOT changing defaultGroup or"
  echo "      serverName; routing only the dnstap monitors to mi_indexer."
  ROUTE="_TCP_ROUTING = mi_indexer"
fi

: > "$UF_HOME/etc/system/local/inputs.conf"
# DNS-collector monitor (source=dnstap:dnscollector)
if [ -n "$NIOS_LOG_PATH" ]; then
  cat >> "$UF_HOME/etc/system/local/inputs.conf" <<EOF
[monitor://${NIOS_LOG_PATH}]
index = ${SPLUNK_INDEX}
sourcetype = ${SPLUNK_SOURCETYPE}
source = dnstap:dnscollector
${ROUTE}
disabled = false
EOF
fi
# Optional Vector monitor (source=dnstap:vector) so the two receivers stay
# distinguishable in the same index. The Vector installer writes this file.
if [ -n "$VECTOR_NIOS_LOG_PATH" ]; then
  cat >> "$UF_HOME/etc/system/local/inputs.conf" <<EOF

[monitor://${VECTOR_NIOS_LOG_PATH}]
index = ${SPLUNK_INDEX}
sourcetype = ${SPLUNK_SOURCETYPE}
source = dnstap:vector
${ROUTE}
disabled = false
EOF
fi
# Optional system-health monitor (source=infoblox:health) — key=value lines from
# scripts/poc_health_snmp.py. Same index, distinct source/sourcetype so the
# infoblox_system_health dashboard and the dnstap searches don't overlap.
if [ -n "$HEALTH_LOG_PATH" ]; then
  cat >> "$UF_HOME/etc/system/local/inputs.conf" <<EOF

[monitor://${HEALTH_LOG_PATH}]
index = ${SPLUNK_INDEX}
sourcetype = ${HEALTH_SOURCETYPE}
source = ${HEALTH_SOURCE}
${ROUTE}
disabled = false
EOF
fi
# server.conf — only on a dedicated UF (renaming a managed forwarder would
# disrupt its deployment-server / indexer identity).
if [ "$MANAGED" = "0" ]; then
  cat > "$UF_HOME/etc/system/local/server.conf" <<EOF
[general]
serverName = $(hostname -s)-dnstap-uf

[httpServer]
disableDefaultPort = true
EOF
fi
# local admin only used for ./bin/splunk CLI on this box; not exposed (no mgmt HTTP)
if [ ! -f "$UF_HOME/etc/system/local/user-seed.conf" ] && [ ! -f "$UF_HOME/etc/passwd" ]; then
  cat > "$UF_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = admin
PASSWORD = $(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
EOF
fi

# the UF must be able to read the dnscollector-owned log dir
if [ -n "$NIOS_LOG_PATH" ]; then
  NIOS_DIR="$(dirname "$NIOS_LOG_PATH")"
  install -d "$NIOS_DIR"
  usermod -a -G dnscollector splunkfwd 2>/dev/null || true
  chmod g+rx "$NIOS_DIR" 2>/dev/null || true
fi
# same for the Vector-owned dir if the second monitor is enabled
if [ -n "$VECTOR_NIOS_LOG_PATH" ]; then
  VEC_DIR="$(dirname "$VECTOR_NIOS_LOG_PATH")"
  install -d "$VEC_DIR"
  usermod -a -G vector splunkfwd 2>/dev/null || true
  chmod g+rx "$VEC_DIR" 2>/dev/null || true
fi
chown -R splunkfwd:splunkfwd "$UF_HOME"

echo "==> Enable boot-start (systemd) + start"
"$UF_HOME/bin/splunk" enable boot-start -systemd-managed 1 -user splunkfwd \
  --accept-license --answer-yes --no-prompt >/dev/null 2>&1 || true
if systemctl daemon-reload 2>/dev/null && systemctl restart SplunkForwarder 2>/dev/null; then
  sleep 5; echo "    SplunkForwarder: $(systemctl is-active SplunkForwarder)"
else
  # no systemd (e.g. WSL2) — foreground service manager
  su -s /bin/bash splunkfwd -c "$UF_HOME/bin/splunk start --accept-license --answer-yes --no-prompt"
fi

echo "==> Verify S2S connection"
sleep 5
if grep -q "Connected to idx=${SPLUNK_IDX_ADDR}" "$UF_HOME/var/log/splunk/splunkd.log"; then
  echo "    OK: S2S handshake with ${SPLUNK_IDX_ADDR}"
else
  echo "    ! no 'Connected to idx' yet — check: tail $UF_HOME/var/log/splunk/splunkd.log"
fi
cat <<EOF

UF monitors ${NIOS_LOG_PATH} -> S2S ${SPLUNK_IDX_ADDR} (index=${SPLUNK_INDEX},
sourcetype=${SPLUNK_SOURCETYPE}, source=dnstap:dnscollector).
Enable the producer side with:
  NIOS_LOG_PATH=${NIOS_LOG_PATH} sudo -E ./install_dnscollector_receiver.sh
Splunk check:  index=${SPLUNK_INDEX} source="dnstap:dnscollector" | stats count by host

RHEL 7.9 notes: UF 9.2.x is the last line for kernel 3.x — don't upgrade past it.
If events stall, check SELinux denials (ausearch -m avc -ts recent | grep splunk)
and firewall egress to ${SPLUNK_IDX_ADDR}.
EOF
