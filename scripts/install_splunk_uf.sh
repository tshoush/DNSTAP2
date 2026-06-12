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

SPLUNK_IDX_ADDR="${SPLUNK_IDX_ADDR:-172.25.15.215:8005}"
NIOS_LOG_PATH="${NIOS_LOG_PATH:-/var/log/dnscollector/nios.log}"
SPLUNK_INDEX="${SPLUNK_INDEX:-mi_dhcp}"
SPLUNK_SOURCETYPE="${SPLUNK_SOURCETYPE:-infoblox:dns}"
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

echo "==> Config (etc/system/local)"
install -d "$UF_HOME/etc/system/local"
cat > "$UF_HOME/etc/system/local/outputs.conf" <<EOF
[tcpout]
defaultGroup = mi_indexer

[tcpout:mi_indexer]
server = ${SPLUNK_IDX_ADDR}
useACK = false
EOF
cat > "$UF_HOME/etc/system/local/inputs.conf" <<EOF
[monitor://${NIOS_LOG_PATH}]
index = ${SPLUNK_INDEX}
sourcetype = ${SPLUNK_SOURCETYPE}
source = dnstap:dnscollector
disabled = false
EOF
cat > "$UF_HOME/etc/system/local/server.conf" <<EOF
[general]
serverName = $(hostname -s)-dnstap-uf

[httpServer]
disableDefaultPort = true
EOF
# local admin only used for ./bin/splunk CLI on this box; not exposed (no mgmt HTTP)
if [ ! -f "$UF_HOME/etc/system/local/user-seed.conf" ] && [ ! -f "$UF_HOME/etc/passwd" ]; then
  cat > "$UF_HOME/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = admin
PASSWORD = $(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
EOF
fi

# the UF must be able to read the dnscollector-owned log dir
NIOS_DIR="$(dirname "$NIOS_LOG_PATH")"
install -d "$NIOS_DIR"
usermod -a -G dnscollector splunkfwd 2>/dev/null || true
chmod g+rx "$NIOS_DIR" 2>/dev/null || true
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
