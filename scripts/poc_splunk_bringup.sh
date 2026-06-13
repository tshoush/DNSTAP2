#!/usr/bin/env bash
# poc_splunk_bringup.sh — ONE command to make this box feed Splunk with DNS
# telemetry, exactly like the verified WSL rig:
#
#   dnstap :6001 -> DNS-collector -> NIOS-style lines -> Splunk UF -> S2S
#   -> indexer splunktcp input -> index=mi_dhcp (sourcetype infoblox:dns)
#
# It self-updates from git, installs/refreshes both services, verifies the
# S2S handshake, then (by default) runs the dnstap simulator so events appear
# in Splunk immediately. When a real NIOS member starts sending dnstap to
# :6001, it flows through the identical path — nothing further to change.
#
# Usage (RHEL 7.9 POC box 172.25.15.234, as root):
#   sudo -E /home/ddi-auto-user/DNSTAP/scripts/poc_splunk_bringup.sh
#
# Tunables (env):
#   SPLUNK_IDX_ADDR  indexer S2S input        (default 172.25.15.215:8005)
#   SPLUNK_INDEX     target index             (default mi_dhcp)
#   NIOS_LOG_PATH    NIOS-lines file          (default /var/log/dnscollector/nios.log)
#   SIMULATE         1 = send synthetic dnstap after install (default 1)
#   SIM_PAIRS        simulated query/response pairs (default 50)
#   SIM_IDENTITY     simulated member name    (default <hostname>-sim)
#   SIM_SERVER_IP    simulated member IP      (default this host's primary IP)
#   SKIP_PULL        1 = don't git pull first (default 0)
#   DRY_RUN          1 = print the steps without executing them
set -euo pipefail

SPLUNK_IDX_ADDR="${SPLUNK_IDX_ADDR:-172.25.15.215:8005}"
SPLUNK_INDEX="${SPLUNK_INDEX:-mi_dhcp}"
NIOS_LOG_PATH="${NIOS_LOG_PATH:-/var/log/dnscollector/nios.log}"
SIMULATE="${SIMULATE:-1}"
SIM_PAIRS="${SIM_PAIRS:-50}"
SIM_IDENTITY="${SIM_IDENTITY:-$(hostname -s)-sim}"
SIM_SERVER_IP="${SIM_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
SKIP_PULL="${SKIP_PULL:-0}"
DRY_RUN="${DRY_RUN:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
UF_HOME=/opt/splunkforwarder

run() { if [ "$DRY_RUN" = "1" ]; then echo "DRY: $*"; else "$@"; fi; }

[ "$DRY_RUN" = "1" ] || [ "$(id -u)" -eq 0 ] || {
  echo "ERROR: run as root (sudo -E)."; exit 1; }

# ── 1. Self-update from git (as the repo owner, then re-exec the new copy) ──
if [ "$SKIP_PULL" != "1" ] && [ -z "${BRINGUP_PULLED:-}" ]; then
  OWNER="$(stat -c %U "$REPO_DIR")"
  echo "==> git pull ($REPO_DIR as $OWNER)"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: runuser -u $OWNER -- git -C $REPO_DIR pull --ff-only"
  else
    if [ "$OWNER" = "$(id -un)" ]; then
      git -C "$REPO_DIR" pull --ff-only
    else
      runuser -u "$OWNER" -- git -C "$REPO_DIR" pull --ff-only
    fi
    # re-exec the (possibly updated) script; BRINGUP_PULLED stops the loop
    BRINGUP_PULLED=1 exec bash "$REPO_DIR/scripts/poc_splunk_bringup.sh"
  fi
fi

# Known gotcha: dnscollector crash-loops if its Loki output can't connect.
if ! curl -s -m 3 -o /dev/null http://localhost:3100/ready 2>/dev/null; then
  echo "    ! WARNING: Loki (:3100) not responding — dnscollector may crash-loop."
  echo "      Bring the stack up first (scripts/install_stack.sh) or restart Loki."
fi

# ── 2. DNS-collector with the NIOS-lines feed ──────────────────────────────
echo "==> DNS-collector (dnstap :6001 + NIOS file ${NIOS_LOG_PATH})"
run env NIOS_LOG_PATH="$NIOS_LOG_PATH" bash "$SCRIPT_DIR/install_dnscollector_receiver.sh"

# ── 3. Splunk Universal Forwarder (S2S to the indexer) ─────────────────────
echo "==> Splunk UF (monitor ${NIOS_LOG_PATH} -> S2S ${SPLUNK_IDX_ADDR})"
run env SPLUNK_IDX_ADDR="$SPLUNK_IDX_ADDR" SPLUNK_INDEX="$SPLUNK_INDEX" \
    NIOS_LOG_PATH="$NIOS_LOG_PATH" bash "$SCRIPT_DIR/install_splunk_uf.sh"

[ "$DRY_RUN" = "1" ] && { echo "DRY: verification + simulation skipped"; exit 0; }

# ── 4. Verify the plumbing ──────────────────────────────────────────────────
echo "==> Verify"
fail=0
if systemctl is-active --quiet dnscollector; then
  echo "    OK: dnscollector service active"
else
  echo "    FAIL: dnscollector not active — cause:"
  systemctl --no-pager -l status dnscollector 2>&1 | sed 's/^/      /' | tail -10 || true
  journalctl -u dnscollector --no-pager 2>&1 | tail -15 | sed 's/^/      /' || true
  echo "      Try: sudo systemctl reset-failed dnscollector && sudo systemctl restart dnscollector"
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    echo "      SELinux Enforcing — check: sudo ausearch -m avc -ts recent | grep dnscollector"
  fi
  fail=1
fi
ss -ltn 2>/dev/null | grep -q ':6001 ' \
  && echo "    OK: dnstap listener on :6001" \
  || { echo "    FAIL: nothing listening on :6001"; fail=1; }
ok_conn=0
for i in $(seq 1 12); do
  if grep -q "Connected to idx=${SPLUNK_IDX_ADDR}" "$UF_HOME/var/log/splunk/splunkd.log" 2>/dev/null; then
    ok_conn=1; break
  fi
  sleep 5
done
[ "$ok_conn" = "1" ] \
  && echo "    OK: UF S2S handshake with ${SPLUNK_IDX_ADDR}" \
  || { echo "    FAIL: no S2S connection (tail $UF_HOME/var/log/splunk/splunkd.log)"; fail=1; }
[ "$fail" = "0" ] || exit 1

# ── 5. Simulated DNS traffic (synthetic NIOS member) ───────────────────────
if [ "$SIMULATE" = "1" ]; then
  echo "==> Simulating ${SIM_PAIRS} query/response pairs (member ${SIM_IDENTITY} @ ${SIM_SERVER_IP})"
  before=$(wc -l < "$NIOS_LOG_PATH" 2>/dev/null || echo 0)
  # collector drops frames that arrive while its outputs are still connecting
  sleep 3
  python3 "$SCRIPT_DIR/dnstap_synth.py" --target 127.0.0.1:6001 \
    --count "$SIM_PAIRS" --rate 40 \
    --server-ip "$SIM_SERVER_IP" --identity "$SIM_IDENTITY"
  grew=0
  for i in $(seq 1 10); do
    sleep 3
    after=$(wc -l < "$NIOS_LOG_PATH" 2>/dev/null || echo 0)
    [ "$after" -gt "$before" ] && { grew=1; break; }
  done
  if [ "$grew" = "1" ]; then
    echo "    OK: ${NIOS_LOG_PATH} +$((after - before)) lines; UF ships them within seconds"
  else
    echo "    FAIL: ${NIOS_LOG_PATH} did not grow — check: journalctl -u dnscollector -n 20"
    exit 1
  fi
fi

# ── 6. What to look at ──────────────────────────────────────────────────────
cat <<EOF

DONE. This box now feeds Splunk; a real NIOS member pointed at
$(hostname -I 2>/dev/null | awk '{print $1}'):6001 (dnstap over TCP) uses the exact same path.

Verify in Splunk (last 60 min):
  index=${SPLUNK_INDEX} source="dnstap:dnscollector" earliest=-60m
  | rex "(?<member>\\S+)\\s+named\\["
  | stats count by member, sourcetype

Expect: member=${SIM_SERVER_IP} (simulated), sourcetype=infoblox:dns,
~$((SIM_PAIRS * 2))+ events, _raw like:
  <ts> ${SIM_SERVER_IP} named[0]: client 10.x.x.x 40444 query: host.example.com IN A CLIENT_RESPONSE NOERROR

Local health:
  systemctl status dnscollector            # receiver
  curl -s localhost:9599/metrics | grep dnscollector_queries_total
  tail -2 ${NIOS_LOG_PATH}                  # NIOS-style lines
  grep 'Connected to idx' $UF_HOME/var/log/splunk/splunkd.log | tail -1
EOF
