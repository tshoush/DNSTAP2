#!/usr/bin/env bash
# run_test_dnstap.sh — interactive POC performance test for the *dnstap* logging mode (M3).
#
# Drives the same query file at the NIOS member while dnstap is enabled and streaming to the
# DNSTAP2 collector, and records DNS-server-side performance + collector-side capture
# (events/s, bytes/event). Pair its results with run_test_querylog.sh and compare via
# process_results.py. See docs/dnstap-value-evidence.md §3–§4.
#
# This script is READ-ONLY against the member and collector. It does NOT enable dnstap —
# you do that once in the Grid Manager GUI (§3.6); this script verifies it's live and tags
# results as mode M3_dnstap. Re-run any test as many times as needed: each run is appended
# with a new run number, so a FAILED test is corrected simply by running it again.
#
# Quick start:
#   export SERVER=10.20.30.40                # the NIOS member under test
#   export QUERYFILE=./scripts/poc/queryfile.example
#   export COLLECTOR_METRICS_URL=http://172.25.15.234:9599/metrics
#   ./scripts/poc/run_test_dnstap.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/poc/lib_poctest.sh
source "$HERE/lib_poctest.sh"

MODE="M3_dnstap"
MODE_HUMAN="dnstap → collector (M3)"
CAPTURE_COLLECTOR=1

# --- dnstap-specific preflight: confirm GUI enablement + events flowing -------------------
preflight_dnstap() {
  pt_preflight_common || return 1
  hdr "dnstap mode check (Grid Manager GUI)"
  cat <<EOF
Confirm on the member under test (Data Management → DNS → Members → member → Edit):
  • Override ✔, Enable dnstap ✔
  • dnstap receiver = ${COLLECTOR_METRICS_URL%%:9599*} : 6001
  • Send client queries ✔ and responses ✔   (native query logging OFF)
  • DNS service restarted, cache re-warmed (the harness also warms before each run)
EOF
  say ""
  say "Checking the collector is receiving events …"
  local ev0 by0 ev1 by1
  read -r ev0 by0 < <(pt_collector_now)
  pt_run_load 50 3 "$RESULTS_DIR/raw/dnstap-check-$(date +%s).txt" >/dev/null 2>&1 || true
  sleep 2
  read -r ev1 by1 < <(pt_collector_now)
  if (( ev1 > ev0 )); then
    ok "collector event count rose ($ev0 → $ev1) — dnstap stream is live"
  else
    err "collector events did NOT increase — dnstap not reaching ${COLLECTOR_METRICS_URL}"
    warn "fix before measuring (GUI enablement, firewall :6001, collector up). See infoblox-ops-playbook.md §2-§4."
    confirm "Continue anyway (results will lack collector capture)?" || return 1
  fi
  if [[ -r "$JSONL_PATH" ]]; then ok "JSONL readable locally — bytes/event will be measured ($JSONL_PATH)"
  else warn "JSONL not local ($JSONL_PATH) — bytes/event skipped; events/s still captured via metrics"; fi
}

# --- dnstap-specific T7: telemetry-loss safety test --------------------------------------
test_T7_failure_dnstap() {
  cat <<EOF
This proves dnstap's safety promise: losing the collector must NOT harm DNS.
Procedure: a steady load runs for ${RUN_SECONDS}s. ~halfway through, YOU kill the
collector (or drop the network to :6001). Watch that DNS latency/loss stays flat —
dnstap drops telemetry, resolution is unaffected.
EOF
  confirm "Start the failure-mode run?" || { warn "T7 skipped"; return 0; }
  warn "≈${RUN_SECONDS}s run starting NOW — kill the collector at the halfway mark."
  pt_measure T7 failure "$QPS_STEADY" "$RUN_SECONDS" 1
  dim "Compare T7 latency/loss to the T3 baseline-with-collector run: they should match."
}

# --- register tests ----------------------------------------------------------------------
TEST_IDS=(   T2 T3 T4 T7 )
TEST_TITLES=(
  "Max QPS ceiling (P2 ramp)"
  "Fixed-load latency/CPU + collector capture (P1)"
  "Soak (P4, long)"
  "Telemetry-loss safety (kill collector)"
)
TEST_DESCS=(
  "Ramp QPS through the sweep (${QPS_SWEEP}); each step ${SWEEP_SECONDS}s. Finds the highest QPS that still meets SLA (lost ≤ ${MAX_LOST_PCT}%). Recorded per step; processor picks the ceiling."
  "Steady ${QPS_STEADY} qps for ${RUN_SECONDS}s after a ${WARMUP_SECONDS}s warm-up. Captures latency/loss, optional server CPU (SNMP), and collector events/s + bytes/event. This is the headline dnstap data point."
  "Steady ${QPS_STEADY} qps for ${SOAK_SECONDS}s. Confirms no latency drift / collector memory creep / drop accumulation over time."
  "Kill the collector mid-load and confirm DNS stays healthy — dnstap's out-of-band safety guarantee."
)
TEST_FUNCS=( test_T2_ceiling test_T3_fixedload test_T4_soak test_T7_failure_dnstap )

# --- main --------------------------------------------------------------------------------
pt_init_results
if ! preflight_dnstap; then err "preflight failed — resolve the above, then re-run."; exit 1; fi
pt_menu
