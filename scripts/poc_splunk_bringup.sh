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
#   RECEIVER         both | dnscollector | vector  (default both)
#                    which receiver(s) to install. "both" runs them side by
#                    side (DNS-collector :6001, Vector :6000) into the same
#                    index, distinguished by source=dnstap:dnscollector vs
#                    source=dnstap:vector. Run this ONCE; everything is
#                    persistent (systemd + UF boot-start) afterwards, so from
#                    then on you only run scripts/poc_simulate_dnstap.sh (or a
#                    real NIOS member points at :6001 / :6000) — no Splunk/
#                    install script ever needs re-running.
#   VECTOR_NIOS_LOG_PATH  Vector's NIOS-lines file  (default /var/log/dnstap/nios.log)
#   SKIP_PULL        1 = don't git pull first (default 0)
#   DRY_RUN          1 = print the steps without executing them
set -euo pipefail

SPLUNK_IDX_ADDR="${SPLUNK_IDX_ADDR:-172.25.15.215:8005}"
SPLUNK_INDEX="${SPLUNK_INDEX:-mi_dhcp}"
NIOS_LOG_PATH="${NIOS_LOG_PATH:-/var/log/dnscollector/nios.log}"
VECTOR_NIOS_LOG_PATH="${VECTOR_NIOS_LOG_PATH:-/var/log/dnstap/nios.log}"
RECEIVER="${RECEIVER:-both}"
case "$RECEIVER" in
  dnscollector) WANT_DC=1; WANT_VEC=0 ;;
  vector)       WANT_DC=0; WANT_VEC=1 ;;
  both)         WANT_DC=1; WANT_VEC=1 ;;
  *) echo "ERROR: RECEIVER must be both | dnscollector | vector (got '$RECEIVER')."; exit 1 ;;
esac
SIMULATE="${SIMULATE:-1}"
SIM_PAIRS="${SIM_PAIRS:-50}"
SIM_IDENTITY="${SIM_IDENTITY:-$(hostname -s)-sim}"
SIM_SERVER_IP="${SIM_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
SKIP_PULL="${SKIP_PULL:-0}"
DRY_RUN="${DRY_RUN:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
UF_HOME=/opt/splunkforwarder
# shellcheck source=/dev/null
. "$SCRIPT_DIR/poc_common.sh"
PYBIN="$(find_python "$REPO_DIR" || true)"

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

echo "==> Receivers: ${RECEIVER}"

# Known gotcha: dnscollector crash-loops if its Loki output can't connect.
if [ "$WANT_DC" = "1" ] && ! curl -s -m 3 -o /dev/null http://localhost:3100/ready 2>/dev/null; then
  echo "    ! WARNING: Loki (:3100) not responding — dnscollector may crash-loop."
  echo "      Bring the stack up first (scripts/install_stack.sh) or restart Loki."
fi

# ── 2. Receiver(s) with the NIOS-lines feed ────────────────────────────────
if [ "$WANT_DC" = "1" ]; then
  echo "==> DNS-collector (dnstap :6001 + NIOS file ${NIOS_LOG_PATH})"
  run env NIOS_LOG_PATH="$NIOS_LOG_PATH" bash "$SCRIPT_DIR/install_dnscollector_receiver.sh"
fi
if [ "$WANT_VEC" = "1" ]; then
  echo "==> Vector (dnstap :6000 + NIOS file ${VECTOR_NIOS_LOG_PATH})"
  run env NIOS_LOG_PATH="$VECTOR_NIOS_LOG_PATH" bash "$SCRIPT_DIR/install_dnstap_receiver.sh"
fi

# ── 3. Splunk Universal Forwarder (S2S to the indexer) ─────────────────────
echo "==> Splunk UF (S2S ${SPLUNK_IDX_ADDR})"
UF_NIOS=""; UF_VEC=""
[ "$WANT_DC" = "1" ] && UF_NIOS="$NIOS_LOG_PATH"
[ "$WANT_VEC" = "1" ] && UF_VEC="$VECTOR_NIOS_LOG_PATH"
run env SPLUNK_IDX_ADDR="$SPLUNK_IDX_ADDR" SPLUNK_INDEX="$SPLUNK_INDEX" \
    NIOS_LOG_PATH="$UF_NIOS" VECTOR_NIOS_LOG_PATH="$UF_VEC" \
    bash "$SCRIPT_DIR/install_splunk_uf.sh"

[ "$DRY_RUN" = "1" ] && { echo "DRY: verification + simulation skipped"; exit 0; }

# ── 4. Verify the plumbing ──────────────────────────────────────────────────
echo "==> Verify"
fail=0
check_svc() {  # $1=service $2=port $3=selinux-grep-term
  if systemctl is-active --quiet "$1"; then
    echo "    OK: $1 service active"
  else
    echo "    FAIL: $1 not active — cause:"
    systemctl --no-pager -l status "$1" 2>&1 | sed 's/^/      /' | tail -10 || true
    journalctl -u "$1" --no-pager 2>&1 | tail -15 | sed 's/^/      /' || true
    echo "      Try: sudo systemctl reset-failed $1 && sudo systemctl restart $1"
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
      echo "      SELinux Enforcing — check: sudo ausearch -m avc -ts recent | grep $3"
    fi
    fail=1
  fi
  ss -ltn 2>/dev/null | grep -q ":$2 " \
    && echo "    OK: dnstap listener on :$2" \
    || { echo "    FAIL: nothing listening on :$2"; fail=1; }
}
[ "$WANT_DC" = "1" ] && check_svc dnscollector 6001 dnscollector
[ "$WANT_VEC" = "1" ] && check_svc vector 6000 vector
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
simulate_into() {  # $1=label $2=port $3=nios-file
  echo "==> Simulating ${SIM_PAIRS} pairs into $1 (:$2, member ${SIM_IDENTITY} @ ${SIM_SERVER_IP})"
  before=$(wc -l < "$3" 2>/dev/null || echo 0)
  sleep 3   # receivers drop frames that arrive while outputs are still connecting
  "${PYBIN:-python3}" "$SCRIPT_DIR/dnstap_synth.py" --target "127.0.0.1:$2" \
    --count "$SIM_PAIRS" --rate 40 \
    --server-ip "$SIM_SERVER_IP" --identity "$SIM_IDENTITY"
  for i in $(seq 1 10); do
    sleep 3
    after=$(wc -l < "$3" 2>/dev/null || echo 0)
    [ "$after" -gt "$before" ] && { echo "    OK: $3 +$((after - before)) lines; UF ships them within seconds"; return 0; }
  done
  echo "    FAIL: $3 did not grow — check: journalctl -u $1 -n 20"
  return 1
}
if [ "$SIMULATE" = "1" ]; then
  [ "$WANT_DC" = "1" ]  && { simulate_into dnscollector 6001 "$NIOS_LOG_PATH" || exit 1; }
  [ "$WANT_VEC" = "1" ] && { simulate_into vector 6000 "$VECTOR_NIOS_LOG_PATH" || exit 1; }
fi

# ── 6. What to look at ──────────────────────────────────────────────────────
cat <<EOF

DONE — the stack is configured and PERSISTENT (systemd services + UF boot-start).
From now on you only send dnstap; nothing here needs re-running:
  * simulate both receivers:  ./scripts/poc_simulate_dnstap.sh
  * or a real NIOS member -> $(hostname -I 2>/dev/null | awk '{print $1}'):6001 (DNS-collector) / :6000 (Vector)
Either way it flows to Splunk (mi_dhcp), Prometheus, Loki and Grafana automatically.

Verify in Splunk (last 60 min) — see both receivers side by side:
  index=${SPLUNK_INDEX} source IN ("dnstap:dnscollector","dnstap:vector") earliest=-60m
  | stats count by source, sourcetype

Expect sourcetype=infoblox:dns, ~$((SIM_PAIRS * 2))+ events per active receiver.
  source=dnstap:dnscollector lines: <ts> <ip> named[0]: client <ip> <port> query: ...
  source=dnstap:vector       lines: <ts> <member> named[id]: client <ip>#<port> (...): query: ...

Local health:
  [ "$WANT_DC" = 1 ] && systemctl status dnscollector; curl -s localhost:9599/metrics | grep dnscollector_queries_total
  [ "$WANT_VEC" = 1 ] && systemctl status vector;       curl -s localhost:9598/metrics | grep dnstap_queries_total
  grep 'Connected to idx' $UF_HOME/var/log/splunk/splunkd.log | tail -1
EOF
