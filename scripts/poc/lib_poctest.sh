#!/usr/bin/env bash
# lib_poctest.sh — shared library for the DNSTAP2 POC performance harness.
#
# Sourced by run_test_dnstap.sh and run_test_querylog.sh. Implements the common
# machinery for the single-server, sequential-mode test described in
# docs/dnstap-value-evidence.md §3:
#   - interactive menu (show what each test does, run / skip / re-run / quit)
#   - dnsperf (or flamethrower) load runs with consistent warm-up (§3.7)
#   - optional server CPU sampling via SNMP (ibPlatformOne — see SNMP-Integration.md)
#   - optional collector-side capture (events/s, drops, bytes/event) for dnstap mode
#   - structured, append-only results (one JSON line per run) so a FAILED test can
#     simply be re-run — a new run number is recorded each time, nothing overwritten.
#
# Nothing here changes the NIOS member; the logging MODE is set by the operator in
# the Grid Manager GUI (§3.6) and merely *declared* to these scripts so results are
# tagged correctly. This library is read-only against the DNS member and collector.

set -uo pipefail   # NOT -e: interactive harness must survive a failed test and continue

# ----------------------------------------------------------------------------- #
# Tunables (env-var overridable, like the standalone installers)
# ----------------------------------------------------------------------------- #
SERVER="${SERVER:-}"                       # NIOS member under test (IP/host) — required
PORT="${PORT:-53}"
QUERYFILE="${QUERYFILE:-}"                  # dnsperf/flame query file — required
RESULTS_DIR="${RESULTS_DIR:-$PWD/poc-results}"

# Load profiles (docs §3.3). QPS_SWEEP drives the T2 ceiling sweep.
QPS_STEADY="${QPS_STEADY:-5000}"           # P1 steady QPS for T3 fixed-load
QPS_SWEEP="${QPS_SWEEP:-1000 2500 5000 10000 20000 40000}"  # P2 ramp steps for T2
RUN_SECONDS="${RUN_SECONDS:-120}"          # measured-run duration for T3
SWEEP_SECONDS="${SWEEP_SECONDS:-30}"       # per-step duration for T2
SOAK_SECONDS="${SOAK_SECONDS:-7200}"       # T4 soak (default 2h)
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"     # throwaway warm-up before each measured run (§3.7); 0 disables
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"     # pause after a mode switch / restart before warm-up
CLIENTS="${CLIENTS:-20}"                   # dnsperf -c
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 4)}"  # dnsperf -T

# Pass/fail thresholds for an automatic verdict (operator can still re-run)
MAX_LOST_PCT="${MAX_LOST_PCT:-1.0}"        # > this many queries lost => FAIL
MIN_COMPLETED_PCT="${MIN_COMPLETED_PCT:-99.0}"

# Server CPU/memory capture via SNMP, using Infoblox's IB-PLATFORMONE-MIB scalars
# (ibSystemMonitor, .1.3.6.1.4.1.7779.3.1.1.2.1.8). These are the standard Infoblox
# enterprise OIDs — NIOS does not expose host CPU via HOST-RESOURCES/UCD. Sampling is
# enabled as soon as SNMP_COMMUNITY is set (OIDs default below; .0 = scalar instance).
SNMP_HOST="${SNMP_HOST:-$SERVER}"
SNMP_COMMUNITY="${SNMP_COMMUNITY:-}"       # v2c community; if blank, SNMP sampling is skipped
SNMP_CPU_OID="${SNMP_CPU_OID:-1.3.6.1.4.1.7779.3.1.1.2.1.8.1.1.0}"  # ibSystemMonitorCpuUsage.0
SNMP_MEM_OID="${SNMP_MEM_OID:-1.3.6.1.4.1.7779.3.1.1.2.1.8.2.1.0}"  # ibSystemMonitorMemUsage.0
SNMP_SAMPLE_INTERVAL="${SNMP_SAMPLE_INTERVAL:-3}"

# Collector-side capture (dnstap mode only). Set by run_test_dnstap.sh.
COLLECTOR_METRICS_URL="${COLLECTOR_METRICS_URL:-http://172.25.15.234:9599/metrics}"
JSONL_PATH="${JSONL_PATH:-/var/log/dnscollector/dnscollector-events.jsonl}"  # only used if locally readable

# Set by each wrapper before calling pt_init
MODE="${MODE:-UNSET}"            # e.g. M3_dnstap, M1_native_q, M2_native_qr, M0_baseline
MODE_HUMAN="${MODE_HUMAN:-unset}"
CAPTURE_COLLECTOR="${CAPTURE_COLLECTOR:-0}"  # 1 in dnstap wrapper

# ----------------------------------------------------------------------------- #
# Pretty output
# ----------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
  C_RST=$'\e[0m'; C_B=$'\e[1m'; C_DIM=$'\e[2m'
  C_GRN=$'\e[32m'; C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_CYN=$'\e[36m'
else
  C_RST=''; C_B=''; C_DIM=''; C_GRN=''; C_RED=''; C_YEL=''; C_CYN=''
fi
say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s%s== %s ==%s\n' "$C_B" "$C_CYN" "$*" "$C_RST"; }
ok()   { printf '%s✓ %s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%s! %s%s\n' "$C_YEL" "$*" "$C_RST"; }
err()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RST"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST"; }

# yes/no prompt, default No
confirm() { local p="${1:-Proceed?}" a; read -r -p "$p [y/N] " a; [[ "$a" =~ ^[Yy] ]]; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ----------------------------------------------------------------------------- #
# Load-tool detection + query-file fingerprint
# ----------------------------------------------------------------------------- #
LOAD_TOOL=""; LOAD_TOOL_VERSION=""
pt_detect_tool() {
  if command -v dnsperf >/dev/null 2>&1; then
    LOAD_TOOL=dnsperf
    LOAD_TOOL_VERSION="$(dnsperf -h 2>&1 | awk '/^Version/{print $2; exit}')"
  elif command -v flame >/dev/null 2>&1; then
    LOAD_TOOL=flame
    LOAD_TOOL_VERSION="$(flame --version 2>&1 | head -1)"
  else
    err "No load generator found. Install dnsperf (preferred) or flamethrower (flame)."
    return 1
  fi
  ok "Load tool: $LOAD_TOOL ${LOAD_TOOL_VERSION:-(unknown version)}"
}

QF_SHA=""; QF_LINES=0
pt_fingerprint_queryfile() {
  [[ -r "$QUERYFILE" ]] || { err "QUERYFILE not readable: ${QUERYFILE:-<unset>}"; return 1; }
  QF_SHA="$(sha256sum "$QUERYFILE" | cut -d' ' -f1)"
  # count non-blank, non-comment lines; never let it be empty (would break JSON)
  QF_LINES="$(grep -c '[^[:space:]]' "$QUERYFILE" 2>/dev/null || true)"
  [[ "$QF_LINES" =~ ^[0-9]+$ ]] || QF_LINES=0
  ok "Query file: $QUERYFILE  ($QF_LINES queries, sha256 ${QF_SHA:0:12}…)"
}

# ----------------------------------------------------------------------------- #
# Results store: one JSON object per line in results.jsonl + per-run raw output.
# Re-running a test appends a NEW line with an incremented run number; the
# processor (process_results.py) takes the latest run per (mode,test,profile).
# ----------------------------------------------------------------------------- #
RESULTS_LOG=""
pt_init_results() {
  mkdir -p "$RESULTS_DIR/raw"
  RESULTS_LOG="$RESULTS_DIR/results.jsonl"
  touch "$RESULTS_LOG"
}

# next run number for a (mode,test,profile) triple
pt_next_run() {
  local test="$1" profile="$2" n
  # grep -c prints 0 and exits 1 on no match; capture cleanly, never double-emit
  n="$(grep -c "\"mode\":\"$MODE\",\"test\":\"$test\",\"profile\":\"$profile\"" "$RESULTS_LOG" 2>/dev/null)" || true
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo $(( n + 1 ))
}

# latest status for a (mode,test) — for the menu status column
pt_latest_status() {
  local test="$1"
  grep "\"mode\":\"$MODE\",\"test\":\"$test\"," "$RESULTS_LOG" 2>/dev/null | tail -1 \
    | grep -oE '"status":"[A-Z]+"' | tail -1 | cut -d'"' -f4
}

# ----------------------------------------------------------------------------- #
# dnsperf runner + parser
# ----------------------------------------------------------------------------- #
# pt_run_load <qps> <seconds> <raw_outfile>  -> writes raw tool output, returns exit code
pt_run_load() {
  local qps="$1" secs="$2" raw="$3"
  if [[ "$LOAD_TOOL" == dnsperf ]]; then
    dnsperf -s "$SERVER" -p "$PORT" -d "$QUERYFILE" \
            -c "$CLIENTS" -T "$THREADS" -l "$secs" -Q "$qps" >"$raw" 2>&1
  else
    # flamethrower: capture raw; parser is best-effort (versions differ)
    flame "$SERVER" -p "$PORT" -f "$QUERYFILE" -Q "$qps" -l "$((secs*1000))" >"$raw" 2>&1
  fi
}

# pt_parse_dnsperf <raw> -> echoes a JSON object of metrics.
# Parsed in Python (already a hard dep via pt_verdict) — avoids mawk/gawk dialect issues
# entirely and is robust to dnsperf version formatting. flame output falls through to null.
pt_parse_dnsperf() {
  python3 - "$1" "$LOAD_TOOL" <<'PY'
import json, re, sys
raw = open(sys.argv[1], errors="replace").read()
tool = sys.argv[2] if len(sys.argv) > 2 else "dnsperf"
m = {k: None for k in ("qps","completed_pct","lost_pct","avg_latency_s","min_latency_s",
                       "max_latency_s","stddev_s","req_size","resp_size")}
m["rcodes"] = ""
if tool == "flame":
    # flamethrower can emit JSON; try to lift common fields, else leave nulls + keep raw.
    try:
        j = json.loads(raw)
        m["qps"] = j.get("qps") or j.get("queries_per_second")
    except Exception:
        pass
else:
    def f(pat):
        g = re.search(pat, raw)
        return float(g.group(1)) if g else None
    m["qps"]          = f(r"Queries per second:\s*([\d.]+)")
    m["completed_pct"]= f(r"Queries completed:.*\(([\d.]+)%\)")
    m["lost_pct"]     = f(r"Queries lost:.*\(([\d.]+)%\)")
    m["avg_latency_s"]= f(r"Average Latency \(s\):\s*([\d.]+)")
    m["min_latency_s"]= f(r"Average Latency.*min ([\d.]+)")
    m["max_latency_s"]= f(r"Average Latency.*max ([\d.]+)")
    m["stddev_s"]     = f(r"Latency StdDev \(s\):\s*([\d.]+)")
    m["req_size"]     = f(r"request (\d+)")
    m["resp_size"]    = f(r"response (\d+)")
    g = re.search(r"Response codes:\s*(.+)", raw)
    if g:
        m["rcodes"] = g.group(1).strip().replace('"', '')
print(json.dumps(m, separators=(",", ":")))
PY
}

# quick connectivity probe (1s of load); returns 0 if any query completed
pt_probe() {
  local raw="$RESULTS_DIR/raw/probe-$(date +%s).txt"
  pt_run_load 5 1 "$raw"
  grep -q "Queries completed:" "$raw" && ! grep -q "completed:[[:space:]]*0 " "$raw"
}

# ----------------------------------------------------------------------------- #
# Optional SNMP server-CPU sampler (background loop while a test runs)
# ----------------------------------------------------------------------------- #
SNMP_SAMPLE_FILE=""; SNMP_PID=""
pt_snmp_start() {
  SNMP_SAMPLE_FILE=""; SNMP_PID=""
  [[ -n "$SNMP_COMMUNITY" && -n "$SNMP_CPU_OID" ]] || return 0
  command -v snmpget >/dev/null 2>&1 || { warn "snmpget not found; skipping server CPU/mem"; return 0; }
  SNMP_SAMPLE_FILE="$(mktemp)"
  ( while :; do
      cpu="$(snmpget -v2c -c "$SNMP_COMMUNITY" -Oqv "$SNMP_HOST" "$SNMP_CPU_OID" 2>/dev/null | tr -dc '0-9.')"
      mem="$(snmpget -v2c -c "$SNMP_COMMUNITY" -Oqv "$SNMP_HOST" "$SNMP_MEM_OID" 2>/dev/null | tr -dc '0-9.')"
      [[ -n "$cpu" ]] && printf '%s %s\n' "${cpu:-}" "${mem:-}" >>"$SNMP_SAMPLE_FILE"
      sleep "$SNMP_SAMPLE_INTERVAL"
    done ) &
  SNMP_PID=$!
}
pt_snmp_stop() {   # echoes {"samples":n,"cpu_avg":..,"cpu_max":..,"mem_avg":..,"mem_max":..} or null
  [[ -n "$SNMP_PID" ]] && kill "$SNMP_PID" 2>/dev/null
  local out="null"
  if [[ -n "$SNMP_SAMPLE_FILE" && -s "$SNMP_SAMPLE_FILE" ]]; then
    out="$(awk '
      {n++; cs+=$1; if($1>cmx)cmx=$1; if($2!=""){ms+=$2; if($2>mmx)mmx=$2; mn++}}
      END{printf "{\"samples\":%d,\"cpu_avg\":%.1f,\"cpu_max\":%.1f,\"mem_avg\":%s,\"mem_max\":%s}",
          n, (n?cs/n:0), cmx, (mn?sprintf("%.1f",ms/mn):"null"), (mn?sprintf("%.1f",mmx):"null")}' \
      "$SNMP_SAMPLE_FILE")"
    rm -f "$SNMP_SAMPLE_FILE"
  fi
  echo "$out"
}

# ----------------------------------------------------------------------------- #
# Collector-side capture (dnstap mode). Returns events count + jsonl bytes "now".
# Prefers local JSONL (gives bytes/event); falls back to collector metrics.
# ----------------------------------------------------------------------------- #
pt_collector_now() {   # echoes "<events> <bytes>"  (bytes=-1 if unknown)
  local ev=0 by=-1
  if [[ -r "$JSONL_PATH" ]]; then
    ev="$(wc -l < "$JSONL_PATH" 2>/dev/null || echo 0)"
    by="$(stat -c%s "$JSONL_PATH" 2>/dev/null || echo -1)"
  else
    ev="$(curl -s --max-time 4 "$COLLECTOR_METRICS_URL" 2>/dev/null \
          | awk '/^dnscollector_(queries|replies)_total/{s+=$NF} END{printf "%d", s}')"
    [[ -z "$ev" ]] && ev=0
  fi
  echo "$ev $by"
}

# ----------------------------------------------------------------------------- #
# Warm-up (cache-state control, §3.7) — identical budget before every measured run
# ----------------------------------------------------------------------------- #
pt_warmup() {
  (( WARMUP_SECONDS > 0 )) || { dim "warm-up disabled (WARMUP_SECONDS=0)"; return 0; }
  dim "warm-up: ${WARMUP_SECONDS}s at ${QPS_STEADY} qps (discarded)…"
  pt_run_load "$QPS_STEADY" "$WARMUP_SECONDS" "$RESULTS_DIR/raw/warmup-$(date +%s).txt" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------- #
# Persist one run as a JSON line (+ keep raw file path)
# ----------------------------------------------------------------------------- #
# pt_save <test> <profile> <status> <params_json> <metrics_json> <cpu_json> <collector_json> <raw>
pt_save() {
  local test="$1" profile="$2" status="$3" params="$4" metrics="$5" cpu="$6" coll="$7" raw="$8"
  local run; run="$(pt_next_run "$test" "$profile")"
  local line
  line=$(printf '{"schema":"poctest/1","ts":"%s","mode":"%s","test":"%s","profile":"%s","run":%s,"status":"%s","server":"%s","load_tool":{"name":"%s","version":"%s"},"queryfile":{"path":"%s","sha256":"%s","lines":%s},"params":%s,"metrics":%s,"server_util":%s,"collector":%s,"raw":"%s"}' \
    "$(now_iso)" "$MODE" "$test" "$profile" "$run" "$status" "$SERVER" \
    "$LOAD_TOOL" "$LOAD_TOOL_VERSION" "$QUERYFILE" "$QF_SHA" "$QF_LINES" \
    "$params" "$metrics" "$cpu" "$coll" "$raw")
  echo "$line" >>"$RESULTS_LOG"
  if [[ "$status" == PASS ]]; then ok "saved run #$run — $status  ($RESULTS_LOG)"; else err "saved run #$run — $status  ($RESULTS_LOG)"; fi
}

# verdict from parsed metrics JSON (uses python for safe float compare)
pt_verdict() {  # <metrics_json> -> echoes PASS/FAIL
  python3 - "$1" "$MAX_LOST_PCT" "$MIN_COMPLETED_PCT" <<'PY' 2>/dev/null || echo FAIL
import json,sys
m=json.loads(sys.argv[1]); maxlost=float(sys.argv[2]); mincomp=float(sys.argv[3])
lost=m.get("lost_pct"); comp=m.get("completed_pct")
ok = (lost is not None and lost<=maxlost) and (comp is not None and comp>=mincomp)
print("PASS" if ok else "FAIL")
PY
}

# ----------------------------------------------------------------------------- #
# Generic measured-run engine used by T3/T4 and each T2 step
# ----------------------------------------------------------------------------- #
# pt_measure <test> <profile> <qps> <seconds> [do_warmup=1]
pt_measure() {
  local test="$1" profile="$2" qps="$3" secs="$4" do_warm="${5:-1}"
  local raw="$RESULTS_DIR/raw/${MODE}-${test}-${profile}-q${qps}-$(date +%s).txt"
  [[ "$do_warm" == 1 ]] && pt_warmup
  local c0 c1 ev0 ev1 by0 by1 coll="null"
  if [[ "$CAPTURE_COLLECTOR" == 1 ]]; then read -r ev0 by0 < <(pt_collector_now); fi
  pt_snmp_start
  say "running: ${qps} qps for ${secs}s …"
  pt_run_load "$qps" "$secs" "$raw"
  local cpu; cpu="$(pt_snmp_stop)"
  local metrics; metrics="$(pt_parse_dnsperf "$raw")"
  if [[ "$CAPTURE_COLLECTOR" == 1 ]]; then
    read -r ev1 by1 < <(pt_collector_now)
    local dev=$(( ev1 - ev0 )) dby=$(( by1<0||by0<0 ? -1 : by1 - by0 ))
    local eps bpe
    eps="$(python3 -c "print(round($dev/$secs,1)) if $secs else print(0)" 2>/dev/null || echo 0)"
    if (( dby >= 0 && dev > 0 )); then bpe="$(python3 -c "print(round($dby/$dev,1))")"; else bpe="null"; fi
    coll="$(printf '{"events_delta":%s,"events_per_s":%s,"bytes_per_event":%s}' "$dev" "$eps" "$bpe")"
  fi
  local params; params="$(printf '{"qps":%s,"seconds":%s,"clients":%s,"threads":%s,"warmup_s":%s}' "$qps" "$secs" "$CLIENTS" "$THREADS" "$WARMUP_SECONDS")"
  local verdict; verdict="$(pt_verdict "$metrics")"
  printf '  %s→ qps=%s lost=%s%% avg=%ss%s\n' "$C_DIM" \
    "$(echo "$metrics" | grep -oE '"qps":[0-9.]+' | cut -d: -f2)" \
    "$(echo "$metrics" | grep -oE '"lost_pct":[0-9.]+' | cut -d: -f2)" \
    "$(echo "$metrics" | grep -oE '"avg_latency_s":[0-9.]+' | cut -d: -f2)" "$C_RST"
  pt_save "$test" "$profile" "$verdict" "$params" "$metrics" "$cpu" "$coll" "$raw"
  [[ "$verdict" == PASS ]]
}

# ----------------------------------------------------------------------------- #
# Interactive menu engine.
# Tests are declared by the wrapper as parallel arrays:
#   TEST_IDS=(T2 T3 ...) ; TEST_TITLES=(...) ; TEST_DESCS=(...) ; TEST_FUNCS=(...)
# ----------------------------------------------------------------------------- #
pt_menu() {
  while true; do
    hdr "DNSTAP2 POC harness — mode: ${C_B}${MODE_HUMAN}${C_RST}${C_CYN} (tag: $MODE)"
    printf '%sServer:%s %s   %sQueryfile:%s %s   %sResults:%s %s\n' \
      "$C_DIM" "$C_RST" "${SERVER:-<unset>}" "$C_DIM" "$C_RST" "${QUERYFILE:-<unset>}" "$C_DIM" "$C_RST" "$RESULTS_LOG"
    echo
    local i st col
    for i in "${!TEST_IDS[@]}"; do
      st="$(pt_latest_status "${TEST_IDS[$i]}")"
      case "$st" in
        PASS) col="${C_GRN}PASS${C_RST}";;
        FAIL) col="${C_RED}FAIL${C_RST}";;
        *)    col="${C_DIM}—   ${C_RST}";;
      esac
      printf '  %s%2d%s) [%s] %s%-26s%s %s\n' "$C_B" $((i+1)) "$C_RST" "$col" "$C_B" "${TEST_IDS[$i]}: ${TEST_TITLES[$i]}" "$C_RST" ""
    done
    echo
    dim "  enter a number to run/re-run a test · 'a' run all not-yet-PASS · 'p' process results · 'q' quit"
    local choice; read -r -p "> " choice
    case "$choice" in
      q|Q) say "bye."; return 0;;
      p|P) pt_run_processor;;
      a|A)
        for i in "${!TEST_IDS[@]}"; do
          [[ "$(pt_latest_status "${TEST_IDS[$i]}")" == PASS ]] && continue
          pt_run_one "$i"
        done;;
      ''|*[!0-9]*) warn "unrecognized choice";;
      *)
        local idx=$((choice-1))
        if (( idx>=0 && idx<${#TEST_IDS[@]} )); then pt_run_one "$idx"; else warn "out of range"; fi;;
    esac
  done
}

pt_run_one() {
  local idx="$1"
  hdr "${TEST_IDS[$idx]} — ${TEST_TITLES[$idx]}"
  printf '%s%s%s\n\n' "$C_DIM" "${TEST_DESCS[$idx]}" "$C_RST"
  if ! confirm "Run this test now?"; then warn "skipped ${TEST_IDS[$idx]}"; return 0; fi
  "${TEST_FUNCS[$idx]}"
}

pt_run_processor() {
  local proc="$(dirname "${BASH_SOURCE[0]}")/process_results.py"
  if [[ -r "$proc" ]]; then python3 "$proc" --results "$RESULTS_LOG"; else warn "process_results.py not found at $proc"; fi
}

# ----------------------------------------------------------------------------- #
# Shared test implementations (used by both wrappers)
# ----------------------------------------------------------------------------- #
test_T2_ceiling() {   # ramp QPS until loss/SLA breaks; each step recorded
  local q
  for q in $QPS_SWEEP; do
    say "── sweep step: ${q} qps ──"
    pt_measure T2 P2_peak "$q" "$SWEEP_SECONDS" 0 || warn "step ${q} qps did not meet SLA (recorded)"
  done
  dim "ceiling = highest step that still met SLA; computed by the processor."
}

test_T3_fixedload() {  # P1 steady, full instrumentation (warm-up applied)
  pt_measure T3 P1_steady "$QPS_STEADY" "$RUN_SECONDS" 1
}

test_T4_soak() {       # long P1 run; watch for drift/leak/log-fill
  warn "soak runs for ${SOAK_SECONDS}s ($(python3 -c "print(round($SOAK_SECONDS/3600,1))")h)."
  confirm "Start the soak now?" || { warn "soak skipped"; return 0; }
  pt_measure T4 P4_soak "$QPS_STEADY" "$SOAK_SECONDS" 1
}

# ----------------------------------------------------------------------------- #
# Common preflight (each wrapper adds its mode-specific reminder before calling)
# ----------------------------------------------------------------------------- #
pt_preflight_common() {
  hdr "Pre-flight"
  pt_detect_tool || return 1
  [[ -n "$SERVER" ]] || { err "SERVER is unset (export SERVER=<member ip>)"; return 1; }
  pt_fingerprint_queryfile || return 1
  say "Probing ${SERVER}:${PORT} with a 1s load …"
  if pt_probe; then ok "server answered queries"; else err "no answers from ${SERVER}:${PORT} — check reachability/zone"; return 1; fi
  if [[ -z "$SNMP_COMMUNITY" ]]; then
    warn "server CPU/mem capture OFF — set SNMP_COMMUNITY to enable (Infoblox OIDs are built in)"
  elif command -v snmpget >/dev/null 2>&1; then
    local t; t="$(snmpget -v2c -c "$SNMP_COMMUNITY" -Oqv "$SNMP_HOST" "$SNMP_CPU_OID" 2>/dev/null | tr -dc '0-9.')"
    if [[ -n "$t" ]]; then ok "server CPU/mem via SNMP OK (ibSystemMonitorCpuUsage now reads ${t}%)"
    else err "SNMP set but no reply for $SNMP_CPU_OID on $SNMP_HOST — check community/ACL/MIB; CPU will be blank"; fi
  else
    warn "snmpget not installed — server CPU/mem capture skipped"
  fi
}
