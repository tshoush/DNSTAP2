#!/usr/bin/env bash
# poc_enable_vector.sh — enable the Vector receiver on this POC box ALONGSIDE
# the running DNS-collector, wire it into the Splunk UF, send a simulated
# batch, and write a full diagnostic report you can commit + push so it can be
# read back. Does NOT touch DNS-collector.
#
#   dnstap :6000 -> Vector -> NIOS lines (/var/log/dnstap/nios.log)
#   -> Splunk UF (source=dnstap:vector) -> S2S 172.25.15.215:8005 -> mi_dhcp
#
# Usage (RHEL 7.9 POC box, after `git pull`):
#   sudo -E /home/ddi-auto-user/DNSTAP/scripts/poc_enable_vector.sh
#   # then push the report back:
#   git add diagnostics/poc-vector-report.txt && git commit -m "vector report" && git push
#
# Tunables (env):
#   SPLUNK_IDX_ADDR  indexer S2S input        (default 172.25.15.215:8005)
#   SPLUNK_INDEX     target index             (default mi_dhcp)
#   VECTOR_NIOS_LOG_PATH  Vector NIOS file     (default /var/log/dnstap/nios.log)
#   NIOS_LOG_PATH    DNS-collector NIOS file   (default /var/log/dnscollector/nios.log;
#                    kept as a UF monitor so DNS-collector keeps flowing)
#   SIM_PAIRS        simulated pairs           (default 50)
#   SIM_SERVER_IP    simulated member IP       (default 162.130.4.21)
#   SIM_IDENTITY     simulated member name     (default hdqncdns01.marriott.com)
#
# Intentionally NOT `set -e`: we want the report to complete even if a step
# fails — that is the whole point of the report.
set -uo pipefail

SPLUNK_IDX_ADDR="${SPLUNK_IDX_ADDR:-172.25.15.215:8005}"
SPLUNK_INDEX="${SPLUNK_INDEX:-mi_dhcp}"
VECTOR_NIOS_LOG_PATH="${VECTOR_NIOS_LOG_PATH:-/var/log/dnstap/nios.log}"
NIOS_LOG_PATH="${NIOS_LOG_PATH:-/var/log/dnscollector/nios.log}"
SIM_PAIRS="${SIM_PAIRS:-50}"
SIM_SERVER_IP="${SIM_SERVER_IP:-162.130.4.21}"
SIM_IDENTITY="${SIM_IDENTITY:-hdqncdns01.marriott.com}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_DIR="$REPO_DIR/diagnostics"
REPORT="$REPORT_DIR/poc-vector-report.txt"
UF_HOME=/opt/splunkforwarder

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo -E)."; exit 1; }
mkdir -p "$REPORT_DIR"

# Tee everything (this script's stdout+stderr, including the installers' output)
# into the report so a single pushed file shows the full run.
exec > >(tee "$REPORT") 2>&1

# On exit, make the report readable/committable by the repo owner and print the
# push commands — even if a step above failed.
finish() {
  OWNER="$(stat -c %U "$REPO_DIR" 2>/dev/null || echo root)"
  chown "$OWNER":"$OWNER" "$REPORT" 2>/dev/null || true
  # this echo goes to the console only (fd redirected), so also append to report
  {
    echo
    echo "==================== NEXT: push this report ===================="
    echo "Report written to: $REPORT"
    echo "As $OWNER, run:"
    echo "  cd $REPO_DIR"
    echo "  git add diagnostics/poc-vector-report.txt"
    echo "  git commit -m 'poc: vector enable diagnostic report'"
    echo "  git push"
  } | tee -a "$REPORT" >/dev/null
  echo
  echo "Report written to: $REPORT — commit + push it (commands appended to the report)."
}
trap finish EXIT

sec() { echo; echo "-------------------- $* --------------------"; }
cap() { echo "\$ $*"; "$@" 2>&1 | sed 's/^/  /'; echo "  [exit $?]"; }

echo "==================== DNSTAP2 POC — ENABLE VECTOR REPORT ===================="
cap date -u
cap hostname -f
cap uname -r
command -v getenforce >/dev/null 2>&1 && cap getenforce

FAILS=""

# ── 1. Install / enable Vector with the NIOS-lines feed ────────────────────
sec "STEP 1: install/enable Vector (:6000, NIOS file $VECTOR_NIOS_LOG_PATH)"
if env NIOS_LOG_PATH="$VECTOR_NIOS_LOG_PATH" bash "$SCRIPT_DIR/install_dnstap_receiver.sh"; then
  echo "  install_dnstap_receiver.sh: exit 0"
else
  echo "  install_dnstap_receiver.sh: FAILED (exit $?)"; FAILS="$FAILS vector-install"
fi
# clear any start-limit lockout and (re)start cleanly
systemctl reset-failed vector >/dev/null 2>&1 || true
systemctl restart vector 2>/dev/null || true
sleep 5

# ── 2. Wire the UF: keep DNS-collector monitor, add the Vector monitor ─────
sec "STEP 2: Splunk UF monitors (dnscollector + vector) -> S2S $SPLUNK_IDX_ADDR"
if env SPLUNK_IDX_ADDR="$SPLUNK_IDX_ADDR" SPLUNK_INDEX="$SPLUNK_INDEX" \
       NIOS_LOG_PATH="$NIOS_LOG_PATH" VECTOR_NIOS_LOG_PATH="$VECTOR_NIOS_LOG_PATH" \
       bash "$SCRIPT_DIR/install_splunk_uf.sh"; then
  echo "  install_splunk_uf.sh: exit 0"
else
  echo "  install_splunk_uf.sh: FAILED (exit $?)"; FAILS="$FAILS uf-install"
fi

# ── 3. Simulate dnstap into Vector (:6000) ─────────────────────────────────
sec "STEP 3: simulate $SIM_PAIRS pairs into Vector (:6000, member $SIM_SERVER_IP)"
before=$(wc -l < "$VECTOR_NIOS_LOG_PATH" 2>/dev/null || echo 0)
sleep 3   # Vector drops frames that arrive while sinks are still connecting
python3 "$SCRIPT_DIR/dnstap_synth.py" --target 127.0.0.1:6000 \
  --count "$SIM_PAIRS" --rate 40 \
  --server-ip "$SIM_SERVER_IP" --identity "$SIM_IDENTITY" 2>&1 | sed 's/^/  /'
grew=0
for i in $(seq 1 10); do
  sleep 3
  after=$(wc -l < "$VECTOR_NIOS_LOG_PATH" 2>/dev/null || echo 0)
  [ "$after" -gt "$before" ] && { grew=1; break; }
done
if [ "$grew" = "1" ]; then
  echo "  OK: $VECTOR_NIOS_LOG_PATH +$((after - before)) lines"
else
  echo "  FAIL: $VECTOR_NIOS_LOG_PATH did not grow"; FAILS="$FAILS vector-nios-file"
fi

# ── 4. Diagnostic snapshot ─────────────────────────────────────────────────
echo
echo "==================== DIAGNOSTIC SNAPSHOT ===================="

sec "[vector] binary + service"
cap /usr/local/bin/vector --version
cap systemctl is-active vector
systemctl --no-pager -l status vector 2>&1 | sed 's/^/  /' | head -15
echo "  ---- journal (last 25) ----"
journalctl -u vector --no-pager 2>&1 | tail -25 | sed 's/^/  /'

sec "[vector] listener + metrics"
cap bash -c "ss -ltnp 2>/dev/null | grep -E ':(6000|9598)' || echo 'NONE on :6000/:9598'"
cap bash -c "curl -s -m5 localhost:9598/metrics | grep -E '^dnstap_(queries|responses)_total' | head -10 || echo 'metrics unreachable'"

sec "[dnscollector] context (should remain active)"
cap systemctl is-active dnscollector
cap bash -c "ss -ltn 2>/dev/null | grep -E ':6001' || echo 'NONE on :6001'"

sec "[nios files] ownership + latest lines"
cap bash -c "ls -l '$VECTOR_NIOS_LOG_PATH' '$NIOS_LOG_PATH' 2>&1"
echo "  ---- tail $VECTOR_NIOS_LOG_PATH (vector; expect client ip#port) ----"
tail -3 "$VECTOR_NIOS_LOG_PATH" 2>&1 | sed 's/^/  /'
echo "  ---- tail $NIOS_LOG_PATH (dnscollector) ----"
tail -3 "$NIOS_LOG_PATH" 2>&1 | sed 's/^/  /'

sec "[UF] service + config + connection"
cap systemctl is-active SplunkForwarder
echo "  ---- inputs.conf ----"
cat "$UF_HOME/etc/system/local/inputs.conf" 2>&1 | sed 's/^/  /'
echo "  ---- outputs.conf ----"
cat "$UF_HOME/etc/system/local/outputs.conf" 2>&1 | sed 's/^/  /'
echo "  ---- 'Connected to idx' (last 3) ----"
grep "Connected to idx" "$UF_HOME/var/log/splunk/splunkd.log" 2>/dev/null | tail -3 | sed 's/^/  /' || echo "  (none)"
echo "  ---- tcpout queue (last 2; current_size ~0 = shipped) ----"
grep "name=tcpout" "$UF_HOME/var/log/splunk/metrics.log" 2>/dev/null | tail -2 | sed 's/^/  /' || echo "  (none)"
echo "  ---- UF errors (last 8) ----"
grep -E ' ERROR ' "$UF_HOME/var/log/splunk/splunkd.log" 2>/dev/null | tail -8 | sed 's/^/  /' || echo "  (none)"

sec "[selinux] recent denials (vector / splunk)"
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
  ausearch -m avc -ts recent 2>/dev/null | grep -iE 'vector|splunk' | tail -10 | sed 's/^/  /' || echo "  (no matching denials)"
else
  echo "  (SELinux not enforcing)"
fi

sec "SUMMARY"
if [ -z "$FAILS" ]; then
  echo "  RESULT: PASS — Vector enabled and feeding the UF."
  echo "  Splunk: index=$SPLUNK_INDEX source=\"dnstap:vector\" earliest=-30m | stats count"
else
  echo "  RESULT: ISSUES ->$FAILS"
  echo "  (snapshot above has the cause: service journal / SELinux / nios file)"
fi
