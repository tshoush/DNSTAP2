#!/usr/bin/env bash
# install_dnstap_receiver.sh — one-shot installer for the Infoblox NIOS dnstap
# receiver (Vector) on RHEL/CentOS/Rocky/Alma 7/8/9. Self-contained: installs
# the Vector binary, writes a known-good vector.toml, sets up the systemd
# service + firewall, then starts and verifies it.
#
# Incorporates the lab fixes (2026-05):
#   - musl Vector build (works on RHEL 7's old glibc)
#   - internal_metrics fed into the Prometheus exporter so /metrics is never
#     empty (and can't be wedged into a no-response state)
#   - correct Vector-0.39 dnstap field paths (.requestData/.responseData) with
#     VRL-safe if/null coalescing (never `?? null` on infallible paths)
#   - clean metric names: dnstap_queries_total{qtype}, dnstap_responses_total{rcode}
#
# Usage:  sudo ./install_dnstap_receiver.sh
# Tunables via env:
#   VECTOR_VERSION (default 0.39.0)
#   LISTEN_PORT    dnstap frame-streams port  (default 6000)
#   METRICS_PORT   Prometheus exporter port   (default 9598)
#   JSONL_PATH     decoded-events archive     (default /var/log/dnstap/events.jsonl)
set -euo pipefail

VECTOR_VERSION="${VECTOR_VERSION:-0.39.0}"
LISTEN_PORT="${LISTEN_PORT:-6000}"
METRICS_PORT="${METRICS_PORT:-9598}"
JSONL_PATH="${JSONL_PATH:-/var/log/dnstap/events.jsonl}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"      # Grafana Loki (set "" to omit)
SYSLOG_ADDR="${SYSLOG_ADDR:-127.0.0.1:514}"        # syslog/SIEM UDP target (set "" to omit)
CONFIG=/etc/vector/vector.toml
BIN=/usr/local/bin/vector

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)."; exit 1; }

case "$(uname -m)" in
  x86_64)  ARCH_TAG="x86_64-unknown-linux-musl" ;;
  aarch64) ARCH_TAG="aarch64-unknown-linux-musl" ;;
  *) echo "ERROR: unsupported arch $(uname -m)"; exit 1 ;;
esac

echo "==> Installing Vector ${VECTOR_VERSION} (${ARCH_TAG})"
if [ -x "$BIN" ] && "$BIN" --version 2>/dev/null | grep -q "$VECTOR_VERSION"; then
  echo "    $BIN already at ${VECTOR_VERSION}, skipping download"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  URL="https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-${ARCH_TAG}.tar.gz"
  echo "    downloading $URL"
  curl -fSL --retry 3 -o "$TMP/vector.tgz" "$URL"
  # best-effort SHA256 verification
  if curl -fsSL -o "$TMP/vector.sha256" "${URL}.sha256" 2>/dev/null; then
    ( cd "$TMP" && want=$(awk '{print $1}' vector.sha256) \
        && got=$(sha256sum vector.tgz | awk '{print $1}') \
        && [ "$want" = "$got" ] && echo "    SHA256 verified" \
        || { echo "ERROR: SHA256 mismatch"; exit 1; } )
  else
    echo "    ! SHA256 file unavailable, skipping verification"
  fi
  tar -xzf "$TMP/vector.tgz" -C "$TMP"
  install -m 0755 "$(find "$TMP" -type f -name vector -path '*/bin/*' | head -1)" "$BIN"
fi
"$BIN" --version

echo "==> Creating vector user + directories"
id vector >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin vector
install -d -o vector -g vector /var/lib/vector "$(dirname "$JSONL_PATH")" /etc/vector
# Ensure the vector user owns existing state/log files (e.g. a previously
# root-owned events.jsonl) or the file sink can't append.
chown -R vector:vector /var/lib/vector "$(dirname "$JSONL_PATH")" 2>/dev/null || true

# Optional fan-out sinks (built only when the corresponding env var is set).
LOKI_SINK=""
[ -n "$LOKI_URL" ] && LOKI_SINK="$(cat <<LOKI

# Sink: Grafana Loki — decoded events searchable in Grafana alongside metrics.
[sinks.loki]
type = "loki"
inputs = ["dnstap_enriched"]
endpoint = "${LOKI_URL}"
healthcheck.enabled = false
encoding.codec = "json"
labels.job = "dnstap"
labels.source = "infoblox"
labels.message_type = "{{ messageType }}"
LOKI
)"
SYSLOG_SINK=""
[ -n "$SYSLOG_ADDR" ] && SYSLOG_SINK="$(cat <<SYS

# Sink: syslog/SIEM forward (UDP JSON). Repoint SYSLOG_ADDR at your collector.
[sinks.syslog_out]
type = "socket"
inputs = ["dnstap_enriched"]
mode = "udp"
address = "${SYSLOG_ADDR}"
encoding.codec = "json"
SYS
)"

echo "==> Writing $CONFIG"
cat > "$CONFIG" <<EOF
# Vector — Infoblox NIOS dnstap receiver. Installed by install_dnstap_receiver.sh.
data_dir = "/var/lib/vector"

# Receive dnstap frame-streams from NIOS members.
[sources.dnstap_in]
type = "dnstap"
mode = "tcp"
address = "0.0.0.0:${LISTEN_PORT}"
max_frame_length = 102400

# Vector's own metrics -> guarantees /metrics always returns content.
[sources.internal_metrics]
type = "internal_metrics"

# Enrich + normalize. NIOS dnstap (Vector 0.39 decoder) carries the DNS question
# under .requestData (ClientQuery) or .responseData (ClientResponse). Path/array
# access is infallible (missing -> null); coalesce with if/null, NEVER \`?? null\`
# (VRL rejects error-coalescing on infallible exprs: error E651).
[transforms.dnstap_enriched]
type = "remap"
inputs = ["dnstap_in"]
source = '''
.environment = "lab"
.dns_vendor  = "infoblox"
.collector   = "vector"
.qname = .responseData.question[0].domainName
if .qname == null { .qname = .requestData.question[0].domainName }
.qtype = .responseData.question[0].questionType
if .qtype == null { .qtype = .requestData.question[0].questionType }
.rcode  = .responseData.rcodeName
.client = .sourceAddress
'''

# Per-query Prometheus counters.
[transforms.dnstap_metrics]
type = "log_to_metric"
inputs = ["dnstap_enriched"]

[[transforms.dnstap_metrics.metrics]]
type = "counter"
field = "qname"
name = "queries_total"           # namespace -> dnstap_queries_total
namespace = "dnstap"
tags.qtype = "{{ qtype }}"

[[transforms.dnstap_metrics.metrics]]
type = "counter"
field = "rcode"
name = "responses_total"         # -> dnstap_responses_total
namespace = "dnstap"
tags.rcode = "{{ rcode }}"

# Prometheus scrape endpoint (dnstap counters + Vector internal metrics).
[sinks.prom_exporter]
type = "prometheus_exporter"
inputs = ["dnstap_metrics", "internal_metrics"]
address = "0.0.0.0:${METRICS_PORT}"
default_namespace = "dnstap"

# Decoded-events archive (one JSON object per line).
[sinks.jsonl_archive]
type = "file"
inputs = ["dnstap_enriched"]
path = "${JSONL_PATH}"
encoding.codec = "json"
${LOKI_SINK}
${SYSLOG_SINK}
EOF
chown vector:vector "$CONFIG"

echo "==> Validating config"
"$BIN" validate --no-environment "$CONFIG"

echo "==> systemd unit"
cat > /etc/systemd/system/vector.service <<EOF
[Unit]
Description=Vector dnstap receiver (Infoblox NIOS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vector
Group=vector
ExecStart=${BIN} --config ${CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "==> Firewall (best-effort)"
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp" >/dev/null || true
  firewall-cmd --permanent --add-port="${METRICS_PORT}/tcp" >/dev/null || true
  firewall-cmd --reload >/dev/null || true
  echo "    opened ${LISTEN_PORT}/tcp, ${METRICS_PORT}/tcp"
fi

echo "==> Enabling + starting vector"
systemctl daemon-reload
systemctl enable vector >/dev/null 2>&1 || true
systemctl restart vector
sleep 5

echo "==> Status"
systemctl is-active vector && echo "    vector active" || { journalctl -u vector -n 20 --no-pager; exit 1; }
curl -fsS -m5 -o /dev/null -w "    /metrics -> HTTP %{http_code}\n" "http://127.0.0.1:${METRICS_PORT}/metrics" || true

cat <<EOF

Done. dnstap receiver listening on 0.0.0.0:${LISTEN_PORT}.
  Metrics:  http://<this-host>:${METRICS_PORT}/metrics   (dnstap_queries_total / dnstap_responses_total)
  Events:   tail -f ${JSONL_PATH} | jq .

Next: point a NIOS DNS member's dnstap receiver at <this-host>:${LISTEN_PORT}
(member:dns -> dnstap_setting.dnstap_receiver_address/port, enable_dnstap_queries/responses,
use_dnstap_setting=true). NIOS requires DNS Cache Acceleration or Threat Protection
active for dnstap; the vNIOS model's full vCPU/RAM (e.g. IB-V1425 = 4 vCPU/32 GB)
must be provisioned or the ADP engine won't start.
EOF
