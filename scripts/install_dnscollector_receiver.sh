#!/usr/bin/env bash
# install_dnscollector_receiver.sh — install dmachard/DNS-collector as an
# ALTERNATIVE dnstap receiver to Vector (a drop-in Vector replacement for the
# collector role). It runs ALONGSIDE the existing Vector setup on DISTINCT
# ports / service / user / paths, so nothing already deployed breaks. It reuses
# the same Loki / Prometheus / Grafana / rsyslog stack.
#
# Distinct from install_dnstap_receiver.sh (Vector) — do not confuse them:
#     Vector                          DNS-collector (this script)
#     service: vector                 service: dnscollector
#     user:    vector                 user:    dnscollector
#     dnstap:  :6000                  dnstap:  :6001
#     metrics: :9598 (dnstap_*)       metrics: :9599 (dnscollector_*)
#     events:  events.jsonl           events:  dnscollector-events.jsonl
#     loki job: dnstap                loki job: dnscollector
#
# To USE it instead of Vector, point a NIOS member's dnstap receiver at
# <this-host>:6001 (member:dns dnstap_setting.dnstap_receiver_port). Vector stays
# running on :6000 untouched, so you can A/B them or fall back instantly.
#
# Config helpers (download+verify, user, systemd, firewall, verify) mirror
# install_dnstap_receiver.sh. Usage: sudo ./install_dnscollector_receiver.sh
set -euo pipefail

DNSCOL_VERSION="${DNSCOL_VERSION:-2.2.3}"
LISTEN_PORT="${LISTEN_PORT:-6001}"          # dnstap frame-streams (Vector uses 6000)
PROM_PORT="${PROM_PORT:-9599}"              # Prometheus metrics (Vector uses 9598)
TOP_N="${TOP_N:-50}"                        # depth of top-domains/top-requesters gauges (dashboard topk reads up to this)
LOKI_URL="${LOKI_URL:-http://localhost:3100/loki/api/v1/push}"
SYSLOG_ADDR="${SYSLOG_ADDR:-127.0.0.1:514}"
# host:port of a Splunk raw TCP input — set to enable the flat-json Splunk feed
# (one JSON event per line; pair with a line-broken sourcetype like
# dnscollector:json). For NIOS-style syslog lines in Splunk use Vector's
# SPLUNK_HEC_* feed instead (install_dnstap_receiver.sh) — the formats coexist,
# distinguished by sourcetype. Set "" (default) to omit.
SPLUNK_TCP_ADDR="${SPLUNK_TCP_ADDR:-}"
JSONL_PATH="${JSONL_PATH:-/var/log/dnscollector/dnscollector-events.jsonl}"   # OWN dir — never touch Vector's /var/log/dnstap
BIN=/usr/local/bin/dnscollector
CONFIG=/etc/dnscollector/config.yml

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)."; exit 1; }
case "$(uname -m)" in x86_64) A=amd64;; aarch64) A=arm64;; *) echo "unsupported arch"; exit 1;; esac

echo "==> Installing DNS-collector ${DNSCOL_VERSION} (${A})"
if [ -x "$BIN" ] && "$BIN" -version 2>/dev/null | grep -q "$DNSCOL_VERSION"; then
  echo "    already installed, skipping download"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  URL="https://github.com/dmachard/DNS-collector/releases/download/v${DNSCOL_VERSION}/DNS-collector_${DNSCOL_VERSION}_linux_${A}.tar.gz"
  echo "    downloading $URL"
  # Hosts behind a TLS-intercepting proxy whose corporate root CA is not in the
  # trust store fail cert verification. Honor DNSTAP_INSECURE_DOWNLOADS=1 to skip
  # verification up front; otherwise try verified first and fall back to -k.
  case "${DNSTAP_INSECURE_DOWNLOADS:-}" in
    1|true|yes|on|TRUE|YES|ON)
      echo "    ! DNSTAP_INSECURE_DOWNLOADS set — TLS certificate verification disabled"
      curl -fSL --retry 3 -k -o "$TMP/dc.tgz" "$URL" ;;
    *)
      if ! curl -fSL --retry 3 -o "$TMP/dc.tgz" "$URL"; then
        echo "    ! download failed (likely TLS cert verification — no corporate root CA)."
        echo "      retrying WITHOUT certificate verification (-k)..."
        curl -fSL --retry 3 -k -o "$TMP/dc.tgz" "$URL"
      fi ;;
  esac
  tar -xzf "$TMP/dc.tgz" -C "$TMP"
  # binary name has varied across releases; pick the executable, not docs
  SRC="$(find "$TMP" -type f \( -name 'DNScollector' -o -name 'DNS-collector' -o -name 'go-dnscollector' -o -name 'dnscollector' \) | head -1)"
  [ -z "$SRC" ] && SRC="$(find "$TMP" -maxdepth 2 -type f -perm -u+x ! -iname '*.md' ! -iname 'LICENSE*' ! -iname '*.yml' | head -1)"
  [ -n "$SRC" ] || { echo "ERROR: binary not found in tarball"; exit 1; }
  install -m 0755 "$SRC" "$BIN"
fi
"$BIN" -version 2>/dev/null | head -1 || true

echo "==> User + dirs"
id dnscollector >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin dnscollector
install -d -o dnscollector -g dnscollector /etc/dnscollector "$(dirname "$JSONL_PATH")"
chown -R dnscollector:dnscollector "$(dirname "$JSONL_PATH")" 2>/dev/null || true

# Optional Splunk flat-json feed (raw TCP input on the Splunk side).
SPLUNK_PIPELINE=""
SPLUNK_FORWARD=""
if [ -n "$SPLUNK_TCP_ADDR" ]; then
  SPLUNK_HOST="${SPLUNK_TCP_ADDR%:*}"
  SPLUNK_PORT="${SPLUNK_TCP_ADDR##*:}"
  SPLUNK_FORWARD=", splunkout"
  SPLUNK_PIPELINE="$(cat <<SPLK
  # ---- output: Splunk flat-json feed (raw TCP input; sourcetype dnscollector:json) ----
  - name: splunkout
    tcpclient:
      transport: tcp
      remote-address: "${SPLUNK_HOST}"
      remote-port: ${SPLUNK_PORT}
      connect-timeout: 5
      retry-interval: 10
      flush-interval: 2
      mode: flat-json
SPLK
)"
fi

echo "==> Writing $CONFIG"
cat > "$CONFIG" <<EOF
# DNS-collector — dnstap receiver (alternative to Vector). Generated by
# install_dnscollector_receiver.sh. Pipelines model (v2.x).
global:
  trace:
    verbose: false
  server-identity: "dnscollector"
  worker:
    interval-monitor: 10
pipelines:
  # ---- input: dnstap frame-streams from NIOS ----
  - name: tap
    dnstap:
      listen-ip: 0.0.0.0
      listen-port: ${LISTEN_PORT}
    transforms:
      normalize:
        qname-lowercase: true
      # Pair each response with its query and stamp dnstap.latency (seconds).
      # Cache hits answer in <2ms, so latency is the cache-hit proxy when the
      # DNS server only emits client-side dnstap (NIOS exposes only
      # enable_dnstap_queries/responses — no RESOLVER_* events).
      latency:
        enable: true
        measure-latency: true
        unanswered-queries: true
        queries-timeout: 5
    routing-policy:
      forward: [ metrics, lokiout, fileout, syslogout${SPLUNK_FORWARD} ]
      dropped: [ ]
  # ---- output: Prometheus metrics (dnscollector_* on :${PROM_PORT}) ----
  - name: metrics
    prometheus:
      listen-ip: 0.0.0.0
      listen-port: ${PROM_PORT}
      prometheus-prefix: "dnscollector"
      top-n: ${TOP_N}
      basic-auth-enable: false
  # ---- output: Grafana Loki (job=dnscollector; same Loki as Vector) ----
  - name: lokiout
    lokiclient:
      server-url: "${LOKI_URL}"
      job-name: "dnscollector"
      mode: "flat-json"
  # ---- output: local JSONL archive ----
  - name: fileout
    logfile:
      file-path: "${JSONL_PATH}"
      mode: flat-json
      max-size: 100
      max-files: 5
  # ---- output: syslog/SIEM forward (UDP) ----
  - name: syslogout
    syslog:
      transport: udp
      remote-address: "${SYSLOG_ADDR}"
      mode: flat-json
      formatter: rfc5424
${SPLUNK_PIPELINE}
EOF
chown dnscollector:dnscollector "$CONFIG"

echo "==> Validate config (best-effort)"
"$BIN" -config "$CONFIG" -test-config 2>&1 | tail -3 || echo "    (-test-config not supported on this build; relying on service start)"

echo "==> systemd unit (dnscollector.service)"
cat > /etc/systemd/system/dnscollector.service <<EOF
[Unit]
Description=DNS-collector (dnstap receiver; alternative to Vector)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dnscollector
Group=dnscollector
ExecStart=${BIN} -config ${CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "==> Firewall (best-effort)"
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp" >/dev/null || true
  firewall-cmd --permanent --add-port="${PROM_PORT}/tcp" >/dev/null || true
  firewall-cmd --reload >/dev/null || true
fi

echo "==> Enable + start"
systemctl daemon-reload
systemctl enable dnscollector >/dev/null 2>&1 || true
systemctl restart dnscollector
sleep 5
echo "    dnscollector: $(systemctl is-active dnscollector)"
for i in $(seq 1 15); do
  code=$(curl -s -m3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PROM_PORT}/metrics" 2>/dev/null || true)
  [ "$code" = "200" ] && break; sleep 2
done
echo "    /metrics(:${PROM_PORT}) -> ${code:-down}"
cat <<EOF

DNS-collector listening on 0.0.0.0:${LISTEN_PORT} (dnstap), metrics on :${PROM_PORT}.
Vector is untouched on :6000 / :9598. To switch a NIOS member to DNS-collector,
set its dnstap receiver port to ${LISTEN_PORT}. Metrics are prefixed dnscollector_*;
Loki events carry job="dnscollector"; archive at ${JSONL_PATH}.
EOF
