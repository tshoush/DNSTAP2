#!/usr/bin/env bash
# run_test_querylog.sh — interactive POC performance test for NIOS *native query logging*
# (and the logging-OFF baseline). Covers the doc's modes:
#     M0_baseline      — all logging OFF (reference; run at start AND end for the drift check)
#     M1_native_q      — native query logging, queries only
#     M2_native_qr     — native query + response logging (the combo Infoblox warns against)
#
# Drives the SAME query file as run_test_dnstap.sh so the two are directly comparable via
# process_results.py. READ-ONLY against the member — you set the logging mode once in the
# Grid Manager GUI (§3.6) and declare it here so results are tagged correctly. Re-run any
# test freely: each run is appended with a new run number (correct a FAILED test by re-running).
#
# Quick start:
#   export SERVER=10.20.30.40
#   export QUERYFILE=./scripts/poc/queryfile.example
#   ./scripts/poc/run_test_querylog.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/poc/lib_poctest.sh
source "$HERE/lib_poctest.sh"

CAPTURE_COLLECTOR=0   # no off-box pipeline for native logging

# --- choose which mode is currently enabled on the member --------------------------------
choose_mode() {
  hdr "Which logging mode is enabled on the member RIGHT NOW?"
  cat <<EOF
  1) Baseline — ALL logging OFF            (tag M0_baseline; run this first and last)
  2) Native QUERY logging only             (tag M1_native_q)
  3) Native QUERY + RESPONSE logging       (tag M2_native_qr — the heavy mode)
EOF
  local c
  if [[ -n "${POC_MODE:-}" ]]; then c="$POC_MODE"; say "(POC_MODE=$c preselected by the campaign guide)"; else read -r -p "select [1-3]: " c; fi
  case "$c" in
    1) MODE="M0_baseline";  MODE_HUMAN="baseline — logging OFF (M0)";;
    2) MODE="M1_native_q";  MODE_HUMAN="native query logging, queries only (M1)";;
    3) MODE="M2_native_qr"; MODE_HUMAN="native query+response logging (M2)";;
    *) warn "invalid"; return 1;;
  esac
  ok "tagging results as $MODE"
}

# --- query-logging-specific preflight ----------------------------------------------------
preflight_querylog() {
  pt_preflight_common || return 1
  hdr "Logging-mode reminder (Grid Manager GUI)"
  case "$MODE" in
    M0_baseline)
      cat <<EOF
Confirm ALL logging is OFF on the member (member → Edit → Logging: query & response logging
unchecked; dnstap unchecked). This M0 run is the reference. Run it again at the very end
(it gets a new run number) so the processor can verify no temporal drift (M0' ≈ M0, §3.2).
EOF
      ;;
    M1_native_q)
      cat <<EOF
Confirm native QUERY logging is ON (queries only), response logging OFF, dnstap OFF
(member → Edit → Logging). Restarted + cache re-warmed.
EOF
      ;;
    M2_native_qr)
      cat <<EOF
Confirm native QUERY *and* RESPONSE logging are BOTH ON, dnstap OFF (member → Edit → Logging).
This is the high-impact mode Infoblox advises against running routinely — that's exactly what
this run quantifies. Restarted + cache re-warmed.
EOF
      ;;
  esac
  say ""
  warn "Native logs are written ON THE MEMBER (syslog/file). This harness measures DNS-server"
  warn "performance (latency/loss/QPS) and, if SNMP is configured, server CPU and disk-write rate"
  warn "— the place native logging's cost shows up. Log *volume* (GB/day) is read off the member"
  warn "directly (e.g. logging stats / disk usage), not by this script."
}

# --- query-logging T7: disk/IO failure mode (guided) ------------------------------------
test_T7_failure_querylog() {
  cat <<EOF
Native logging writes synchronously on the member, so its failure mode is disk/IO pressure.
This is a GUIDED test (you induce the condition on the member, e.g. fill/throttle the log
volume in a lab member) while a steady load runs; record whether resolution degrades.
EOF
  confirm "Start the guided failure run?" || { warn "T7 skipped"; return 0; }
  warn "≈${RUN_SECONDS}s run starting NOW — induce the disk/IO condition at the halfway mark."
  pt_measure T7 failure "$QPS_STEADY" "$RUN_SECONDS" 1
}

# --- register tests ----------------------------------------------------------------------
TEST_IDS=(   T2 T3 T4 T7 )
TEST_TITLES=(
  "Max QPS ceiling (P2 ramp)"
  "Fixed-load latency/CPU/disk (P1)"
  "Soak (P4, long)"
  "Disk/IO failure mode (guided)"
)
TEST_DESCS=(
  "Ramp QPS through the sweep (${QPS_SWEEP}); each step ${SWEEP_SECONDS}s. Finds the highest QPS that still meets SLA (lost ≤ ${MAX_LOST_PCT}%). The penalty vs. M0 baseline is the headline number for this mode."
  "Steady ${QPS_STEADY} qps for ${RUN_SECONDS}s after a ${WARMUP_SECONDS}s warm-up. Captures latency/loss and (if SNMP set) server CPU + disk-write rate — where synchronous query logging costs the member."
  "Steady ${QPS_STEADY} qps for ${SOAK_SECONDS}s. Watches for latency drift, CPU creep, and log-disk fill over time."
  "Induce disk/IO pressure from logging while serving load; record whether DNS resolution degrades (native logging's coupling to the data path)."
)
TEST_FUNCS=( test_T2_ceiling test_T3_fixedload test_T4_soak test_T7_failure_querylog )

# --- main --------------------------------------------------------------------------------
pt_init_results
choose_mode || exit 1
if ! preflight_querylog; then err "preflight failed — resolve the above, then re-run."; exit 1; fi
pt_menu
