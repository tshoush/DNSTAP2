#!/usr/bin/env bash
# poc_simulate_dnstap.sh — send SIMULATED dnstap to the running receivers and
# watch the whole stack light up. Installs nothing, changes nothing: it just
# opens TCP to the local receiver(s), which the persistent services then carry
# all the way to Splunk (index=mi_dhcp), Prometheus, Loki and Grafana.
#
# By DEFAULT it feeds EVERY receiver that is listening:
#   :6001 DNS-collector  -> source=dnstap:dnscollector
#   :6000 Vector         -> source=dnstap:vector
# each as a distinct synthetic NIOS member, so both show up side by side.
#
# Prereq: the stack is configured ONCE (scripts/poc_splunk_bringup.sh). After
# that you only ever run THIS — no need to re-run any install/Splunk script.
# Does NOT need root.
#
# Usage (RHEL 7.9 POC box):
#   ./scripts/poc_simulate_dnstap.sh                 # feed both, 50 pairs each
#   PAIRS=200 ./scripts/poc_simulate_dnstap.sh       # more events
#   DURATION=600 RATE=20 ./scripts/poc_simulate_dnstap.sh   # stream 10 min @ 20/s each
#   TARGET=127.0.0.1:6000 ./scripts/poc_simulate_dnstap.sh  # force a single receiver
#
# Tunables (env):
#   TARGET     force a single receiver host:port (default: auto-detect :6001 + :6000)
#   PAIRS      query/response pairs per receiver (default 50; ignored if DURATION)
#   DURATION   seconds to stream                 (default unset -> use PAIRS)
#   RATE       pairs per second                  (default 40)
#   SPLUNK_INDEX  index for the printed search   (default mi_dhcp)
set -euo pipefail

PAIRS="${PAIRS:-50}"
RATE="${RATE:-40}"
SPLUNK_INDEX="${SPLUNK_INDEX:-mi_dhcp}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNTH="$SCRIPT_DIR/dnstap_synth.py"
[ -f "$SYNTH" ] || { echo "ERROR: $SYNTH not found (run from the repo)."; exit 1; }
# shellcheck source=/dev/null
. "$SCRIPT_DIR/poc_common.sh"
PYBIN="$(find_python "$(dirname "$SCRIPT_DIR")")" \
  || { echo "ERROR: no python3 found (>=3.6). Set PYTHON=/path/to/python3."; exit 1; }

port_open() {  # host port -> 0 if a TCP connect succeeds (no nc dependency)
  timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

# Build the list of (label port identity server_ip) targets to feed.
# Each receiver gets its own member so they're distinct in Splunk; the `source`
# field (dnstap:dnscollector vs dnstap:vector) is the real distinguisher.
ROWS=()
if [ -n "${TARGET:-}" ]; then
  h="${TARGET%:*}"; p="${TARGET##*:}"
  ROWS+=("forced $p iad13ibdns01.marriott.com 162.130.128.97")
  FORCED_HOST="$h"
else
  ROWS+=("dnscollector 6001 iad13ibdns01.marriott.com 162.130.128.97")
  ROWS+=("vector 6000 hdqncdns01.marriott.com 162.130.4.21")
  FORCED_HOST="127.0.0.1"
fi

sent_any=0
fed_labels=""
for row in "${ROWS[@]}"; do
  read -r label port identity server_ip <<<"$row"
  if ! port_open "$FORCED_HOST" "$port"; then
    [ "$label" = "forced" ] \
      && { echo "ERROR: nothing listening on ${TARGET}."; exit 1; } \
      || { echo "==> skip ${label} (:${port} not listening — not installed?)"; continue; }
  fi
  echo "==> Feeding ${label} (${FORCED_HOST}:${port}) as ${identity} / ${server_ip}"
  args=(--target "${FORCED_HOST}:${port}" --rate "$RATE" --recursion-ratio 0.3 \
        --server-ip "$server_ip" --identity "$identity")
  if [ -n "${DURATION:-}" ]; then
    args+=(--duration "$DURATION"); echo "    streaming ~${DURATION}s @ ${RATE}/s"
  else
    args+=(--count "$PAIRS"); echo "    ${PAIRS} query/response pairs"
  fi
  "$PYBIN" "$SYNTH" "${args[@]}"
  sent_any=1; fed_labels="$fed_labels ${label}"
done
[ "$sent_any" = "1" ] || { echo "ERROR: no receivers were listening (:6001 / :6000). Run scripts/poc_splunk_bringup.sh first."; exit 1; }

cat <<EOF

DONE (fed:${fed_labels}). The persistent services carry these to Splunk
(index=${SPLUNK_INDEX}), Prometheus, Loki and Grafana — no install/Splunk script re-run needed.

Verify in Splunk (last 15 min) — both receivers side by side:
  index=${SPLUNK_INDEX} source IN ("dnstap:dnscollector","dnstap:vector") earliest=-15m
  | stats count by source, sourcetype

Per-member breakdown:
  index=${SPLUNK_INDEX} source IN ("dnstap:dnscollector","dnstap:vector") earliest=-15m
  | rex "(?<member>\\d+\\.\\d+\\.\\d+\\.\\d+)\\s+named\\["
  | stats count by source, member

Local health (Grafana http://172.25.15.234:3000/, Prometheus :9090):
  curl -s localhost:9599/metrics | grep dnscollector_queries_total   # DNS-collector
  curl -s localhost:9598/metrics | grep dnstap_queries_total         # Vector
EOF
