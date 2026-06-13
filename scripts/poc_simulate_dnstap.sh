#!/usr/bin/env bash
# poc_simulate_dnstap.sh — send SIMULATED dnstap traffic to the already-running
# receiver so events flow through to Splunk, exactly as a real NIOS member
# would. Install nothing, change nothing: this just feeds DNS-collector on
# :6001, which renders NIOS-style lines that the Splunk UF ships over S2S to
# index=mi_dhcp. Use it to prove the pipeline end-to-end or to keep a demo
# stream running.
#
# Prereq: the pipeline is already up (run scripts/poc_splunk_bringup.sh once).
# Does NOT need root — it only opens a TCP connection to the local receiver.
#
# Usage (RHEL 7.9 POC box):
#   ./scripts/poc_simulate_dnstap.sh                 # 50 pairs, one shot
#   PAIRS=200 ./scripts/poc_simulate_dnstap.sh       # more events
#   DURATION=600 RATE=20 ./scripts/poc_simulate_dnstap.sh   # stream 10 min @ 20/s
#   MEMBERS=3 ./scripts/poc_simulate_dnstap.sh       # 3 distinct synthetic members
#
# Tunables (env):
#   TARGET     receiver host:port            (default 127.0.0.1:6001)
#   PAIRS      query/response pairs to send  (default 50; ignored if DURATION set)
#   DURATION   seconds to stream             (default unset -> use PAIRS)
#   RATE       pairs per second              (default 40)
#   MEMBERS    number of distinct synthetic members (default 1, max 3)
#   SPLUNK_INDEX  index for the printed search (default mi_dhcp)
set -euo pipefail

TARGET="${TARGET:-127.0.0.1:6001}"
PAIRS="${PAIRS:-50}"
RATE="${RATE:-40}"
MEMBERS="${MEMBERS:-1}"
SPLUNK_INDEX="${SPLUNK_INDEX:-mi_dhcp}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNTH="$SCRIPT_DIR/dnstap_synth.py"
[ -f "$SYNTH" ] || { echo "ERROR: $SYNTH not found (run from the repo)."; exit 1; }
# shellcheck source=/dev/null
. "$SCRIPT_DIR/poc_common.sh"
PYBIN="$(find_python "$(dirname "$SCRIPT_DIR")")" \
  || { echo "ERROR: no python3 found (>=3.6). Set PYTHON=/path/to/python3."; exit 1; }

# A few realistic-looking synthetic NIOS members (name, listening IP). The
# server-ip lands in dnstap response_address, so each shows up distinctly in
# Splunk just like multiple real grid members would.
NAMES=("iad13ibdns01.marriott.com" "hdqncdns01.marriott.com" "cmhbribdns01.marriott.com")
IPS=("162.130.128.97" "162.130.4.21" "162.130.66.10")

[ "$MEMBERS" -ge 1 ] || MEMBERS=1
[ "$MEMBERS" -le 3 ] || MEMBERS=3

# Quick reachability check so a misconfigured/stopped receiver fails loudly.
host="${TARGET%:*}"; port="${TARGET##*:}"
if command -v nc >/dev/null 2>&1; then
  nc -z -w 3 "$host" "$port" 2>/dev/null \
    || { echo "ERROR: nothing listening on ${TARGET}. Is DNS-collector up? (systemctl status dnscollector)"; exit 1; }
fi

echo "==> Sending simulated dnstap to ${TARGET} across ${MEMBERS} member(s)"
COMMON=(--target "$TARGET" --rate "$RATE" --recursion-ratio 0.3)
if [ -n "${DURATION:-}" ]; then
  COMMON+=(--duration "$DURATION")
  echo "    streaming ~${DURATION}s @ ${RATE} pairs/s per member"
else
  COMMON+=(--count "$PAIRS")
  echo "    ${PAIRS} query/response pairs per member"
fi

pids=()
for i in $(seq 0 $((MEMBERS - 1))); do
  "$PYBIN" "$SYNTH" "${COMMON[@]}" \
    --server-ip "${IPS[$i]}" --identity "${NAMES[$i]}" &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" = "0" ] || { echo "    ! one or more senders failed"; exit 1; }

cat <<EOF

DONE. Events are in DNS-collector and the Splunk UF ships them within seconds.

Verify in Splunk (last 15 min):
  index=${SPLUNK_INDEX} source="dnstap:dnscollector" earliest=-15m
  | rex "(?<member>\\d+\\.\\d+\\.\\d+\\.\\d+)\\s+named\\["
  | stats count by member, sourcetype

Expect: sourcetype=infoblox:dns, member = the simulated IP(s)
  ($(for i in $(seq 0 $((MEMBERS - 1))); do printf '%s ' "${IPS[$i]}"; done)),
and _raw lines like:
  <ts> 162.130.128.97 named[0]: client 10.x.x.x 40444 query: host.example.com IN A CLIENT_RESPONSE NOERROR

Drill into one member / see queries vs responses:
  index=${SPLUNK_INDEX} source="dnstap:dnscollector" "162.130.128.97" earliest=-15m
  | rex "query: (?<qname>\\S+) IN (?<qtype>\\S+) (?<op>\\S+) (?<rcode>\\S+)"
  | stats count by qtype, op, rcode
EOF
