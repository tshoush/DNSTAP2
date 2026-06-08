#!/usr/bin/env bash
# run_poc_campaign.sh — guided, resumable conductor for the whole dnstap-vs-query-logging POC.
#
# Walks you through the single-server sequential test (docs/dnstap-value-evidence.md §3.4) in
# order — M0 baseline → M1 native queries → M2 native queries+responses → M3 dnstap → M0'
# baseline (drift) → process — and TRACKS YOUR PROGRESS so you can stop and resume any time.
#
# For each step it: tells you exactly what to change in the Grid Manager GUI, waits for you to
# confirm the change + DNS restart, launches the right test script (with the correct mode and
# env wired in), then records the step as DONE / FAILED / SKIPPED in a progress file. The menu
# always shows where you are. Re-run any step as many times as needed.
#
#   ./scripts/poc/run_poc_campaign.sh
#
# It calls run_test_querylog.sh / run_test_dnstap.sh / process_results.py — it does not
# replace them; it sequences and tracks them. READ-ONLY against the member/collector.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/poc/lib_poctest.sh
source "$HERE/lib_poctest.sh"          # reuse pretty helpers (say/hdr/ok/warn/confirm/colors)

RESULTS_DIR="${RESULTS_DIR:-$PWD/poc-results}"
CONFIG_ENV="$RESULTS_DIR/campaign.env"
PROGRESS="$RESULTS_DIR/campaign-progress.tsv"

# --- campaign steps (parallel arrays) ----------------------------------------------------
#   id      label                              action     poc_mode
STEP_IDS=(  M0   M1   M2   M3   M0p  PROC )
STEP_LABELS=(
  "M0  Baseline — all logging OFF (start)"
  "M1  Native QUERY logging only"
  "M2  Native QUERY + RESPONSE logging"
  "M3  dnstap → collector"
  "M0' Baseline again — drift check (end)"
  "Process results & build comparison"
)
STEP_ACTION=( querylog querylog querylog dnstap querylog process )
STEP_POCMODE=( 1 2 3 - 1 - )

# --- per-step GUI guidance ---------------------------------------------------------------
gui_for() {
  case "$1" in
    M0|M0p)
      cat <<EOF
GUI: Data Management → DNS → Members → <member> → Edit → Logging
  • UNCHECK query logging, UNCHECK response logging
  • (Logging tab / dnstap) ensure dnstap is OFF
  • Save → restart DNS if prompted
This is the no-logging reference. ${1:+}$([ "$1" = M0p ] && echo "Running it again at the END proves no temporal drift (M0' ≈ M0).")
EOF
      ;;
    M1)
      cat <<EOF
GUI: Data Management → DNS → Members → <member> → Edit → Logging
  • CHECK query logging (queries only)
  • Response logging OFF, dnstap OFF
  • Save → restart DNS if prompted
EOF
      ;;
    M2)
      cat <<EOF
GUI: Data Management → DNS → Members → <member> → Edit → Logging
  • CHECK query logging AND response logging (both)
  • dnstap OFF
  • Save → restart DNS if prompted
  ⚠ This is the heavy mode Infoblox advises against running routinely — that's the point.
EOF
      ;;
    M3)
      cat <<EOF
GUI: Data Management → DNS → Members → <member> → Edit  (near Logging)
  • Tick Override (use member dnstap setting), Enable dnstap ✔
  • dnstap receiver = ${COLLECTOR_HOST:-<collector>} : 6001
  • Send client queries ✔ and responses ✔   (native query/response logging OFF)
  • Save → restart DNS if prompted
  The harness will verify events are arriving at the collector before you load.
EOF
      ;;
  esac
}

# --- progress store ----------------------------------------------------------------------
prog_get() { awk -F'\t' -v id="$1" '$1==id{print $2}' "$PROGRESS" 2>/dev/null | tail -1; }
prog_set() {
  local id="$1" status="$2" note="${3:-}"
  mkdir -p "$RESULTS_DIR"; touch "$PROGRESS"
  grep -vP "^$id\t" "$PROGRESS" > "$PROGRESS.tmp" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$id" "$status" "$(now_iso)" "$note" >> "$PROGRESS.tmp"
  mv "$PROGRESS.tmp" "$PROGRESS"
}

icon() {
  case "$1" in
    DONE)    printf '%s✓%s' "$C_GRN" "$C_RST";;
    FAILED)  printf '%s✗%s' "$C_RED" "$C_RST";;
    SKIPPED) printf '%s⊘%s' "$C_YEL" "$C_RST";;
    *)       printf '%s·%s' "$C_DIM" "$C_RST";;
  esac
}

# --- settings ----------------------------------------------------------------------------
ask_default() { local p="$1" d="$2" a; read -r -p "$p [${d:-none}]: " a; echo "${a:-$d}"; }

collect_settings() {
  hdr "Campaign settings"
  [[ -r "$CONFIG_ENV" ]] && { source "$CONFIG_ENV"; dim "loaded saved settings from $CONFIG_ENV"; }
  SERVER="$(ask_default 'NIOS member under test (IP/host)' "${SERVER:-}")"
  QUERYFILE="$(ask_default 'Query file (dnsperf format)' "${QUERYFILE:-$HERE/queryfile.example}")"
  COLLECTOR_HOST="$(ask_default 'Collector host/IP (for dnstap mode)' "${COLLECTOR_HOST:-172.25.15.234}")"
  COLLECTOR_METRICS_URL="http://${COLLECTOR_HOST}:9599/metrics"
  JSONL_PATH="$(ask_default 'Collector JSONL path (only if running ON the collector; blank to skip bytes/event)' "${JSONL_PATH:-}")"
  SNMP_COMMUNITY="$(ask_default 'SNMP v2c community for member CPU/mem (blank = skip)' "${SNMP_COMMUNITY:-}")"
  QPS_STEADY="$(ask_default 'Steady QPS for T3 (P1)' "${QPS_STEADY:-5000}")"
  QPS_SWEEP="$(ask_default 'QPS sweep for T2 (P2 ramp)' "${QPS_SWEEP:-1000 2500 5000 10000 20000 40000}")"

  mkdir -p "$RESULTS_DIR"
  cat > "$CONFIG_ENV" <<EOF
# saved by run_poc_campaign.sh — edit freely
export SERVER="$SERVER"
export QUERYFILE="$QUERYFILE"
export COLLECTOR_HOST="$COLLECTOR_HOST"
export COLLECTOR_METRICS_URL="$COLLECTOR_METRICS_URL"
export JSONL_PATH="$JSONL_PATH"
export SNMP_COMMUNITY="$SNMP_COMMUNITY"
export QPS_STEADY="$QPS_STEADY"
export QPS_SWEEP="$QPS_SWEEP"
export RESULTS_DIR="$RESULTS_DIR"
EOF
  # export for child scripts
  export SERVER QUERYFILE COLLECTOR_HOST COLLECTOR_METRICS_URL JSONL_PATH \
         SNMP_COMMUNITY QPS_STEADY QPS_SWEEP RESULTS_DIR
  ok "settings saved to $CONFIG_ENV (re-edit any time with 's')"
}

# --- run one step ------------------------------------------------------------------------
step_index() { local id="$1" i; for i in "${!STEP_IDS[@]}"; do [[ "${STEP_IDS[$i]}" == "$id" ]] && { echo "$i"; return; }; done; echo -1; }

do_step() {
  local i="$1" id="${STEP_IDS[$1]}" action="${STEP_ACTION[$1]}" pm="${STEP_POCMODE[$1]}"
  hdr "Step ${STEP_LABELS[$i]}"

  if [[ "$action" == process ]]; then
    python3 "$HERE/process_results.py" --results "$RESULTS_DIR/results.jsonl"
    prog_set "$id" DONE "processed"
    return
  fi

  # 1) GUI guidance + confirm
  gui_for "$id"
  echo
  warn "After the GUI change, DNS restarts and the cache is cold — the harness auto-warms"
  warn "(${WARMUP_SECONDS:-30}s) before each measured run, but give the member a moment to settle."
  if ! confirm "Have you applied the GUI change for $id and restarted DNS?"; then
    warn "step $id not started"; return
  fi

  # 2) launch the right test script with mode/env wired in
  say ""; dim "launching the $action test harness for $id …"; echo
  local rc=0
  if [[ "$action" == querylog ]]; then
    POC_MODE="$pm" bash "$HERE/run_test_querylog.sh" || rc=$?
  else
    bash "$HERE/run_test_dnstap.sh" || rc=$?
  fi

  # 3) record outcome
  echo
  hdr "Step $id — outcome"
  say "Mark this step: [d]one · [f]ailed (re-run later) · [s]kip · [enter]=leave as-is"
  local a; read -r -p "> " a
  case "$a" in
    d|D) prog_set "$id" DONE;;
    f|F) prog_set "$id" FAILED;;
    s|S) prog_set "$id" SKIPPED;;
    *)   dim "left unchanged (status: $(prog_get "$id" || echo PENDING))";;
  esac
}

# --- main menu ---------------------------------------------------------------------------
show_board() {
  hdr "DNSTAP2 POC campaign — progress"
  printf '%sServer:%s %s   %sResults:%s %s\n\n' "$C_DIM" "$C_RST" "${SERVER:-<unset>}" "$C_DIM" "$C_RST" "$RESULTS_DIR"
  local i id st ts
  for i in "${!STEP_IDS[@]}"; do
    id="${STEP_IDS[$i]}"; st="$(prog_get "$id")"; st="${st:-PENDING}"
    ts="$(awk -F'\t' -v id="$id" '$1==id{print $3}' "$PROGRESS" 2>/dev/null | tail -1)"
    printf '  %s%d%s) [%s] %-42s %s%s%s\n' "$C_B" $((i+1)) "$C_RST" "$(icon "$st")" "${STEP_LABELS[$i]}" "$C_DIM" "${ts:-}" "$C_RST"
  done
  echo
  dim "  number = do/re-do step · 'n' next pending · 'p' process · 's' settings · 'r' reset · 'q' quit"
}

main() {
  mkdir -p "$RESULTS_DIR"; touch "$PROGRESS"
  hdr "Welcome — guided dnstap vs. query-logging POC"
  cat <<EOF
This guide runs ONE NIOS member through each logging mode with the SAME query file and
records the results, so you get an apples-to-apples comparison. You'll switch each mode in
the Grid Manager GUI (the guide tells you exactly what to click), then it runs the load test.
Your progress is saved — stop and resume any time. Recommended: do the steps top to bottom.
EOF
  if [[ -r "$CONFIG_ENV" ]]; then
    source "$CONFIG_ENV"
    export SERVER QUERYFILE COLLECTOR_HOST COLLECTOR_METRICS_URL JSONL_PATH SNMP_COMMUNITY QPS_STEADY QPS_SWEEP RESULTS_DIR
    say ""; ok "resumed saved settings ($CONFIG_ENV) — choose 's' to change them"
  else
    collect_settings
  fi

  while true; do
    show_board
    local choice; read -r -p "> " choice
    case "$choice" in
      q|Q) say "progress saved in $PROGRESS — resume any time."; exit 0;;
      p|P) python3 "$HERE/process_results.py" --results "$RESULTS_DIR/results.jsonl";;
      s|S) collect_settings;;
      r|R) confirm "Reset all step progress (results.jsonl is kept)?" && : > "$PROGRESS" && ok "progress reset";;
      n|N)
        local i done_any=0
        for i in "${!STEP_IDS[@]}"; do
          local st; st="$(prog_get "${STEP_IDS[$i]}")"
          if [[ "$st" != DONE ]]; then do_step "$i"; done_any=1; break; fi
        done
        (( done_any )) || ok "all steps DONE 🎉";;
      ''|*[!0-9]*) warn "unrecognized";;
      *)
        local idx=$((choice-1))
        if (( idx>=0 && idx<${#STEP_IDS[@]} )); then do_step "$idx"; else warn "out of range"; fi;;
    esac
  done
}

main
