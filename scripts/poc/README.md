# POC performance harness — dnstap vs. native query logging

Interactive scripts that execute the **single-server, sequential-mode** test from
[`docs/dnstap-value-evidence.md`](../../docs/dnstap-value-evidence.md): one NIOS member,
the **same query file** replayed by `dnsperf` (or `flamethrower`) under each logging mode,
recording DNS-server performance and (for dnstap) collector-side capture.

| Script | Role |
|---|---|
| **`run_poc_campaign.sh`** | **Start here.** Guided, resumable conductor — walks you through every mode in order, tells you the exact GUI change for each, launches the right test, and **tracks your progress** (stop/resume any time). |
| `run_test_dnstap.sh` | runs the test suite in **dnstap** mode (M3), plus collector capture + telemetry-loss safety test |
| `run_test_querylog.sh` | runs it in **native query logging** mode — M0 baseline / M1 queries-only / M2 queries+responses |
| `process_results.py` | reads `results.jsonl` → drift check, QPS-ceiling, fixed-load, and storage tables |
| `lib_poctest.sh` | shared engine (sourced by the others — not run directly) |
| `queryfile.example` | sample dnsperf query file (pure `qname qtype` lines) |

## Easiest path: the guide

```bash
./scripts/poc/run_poc_campaign.sh
```

It asks for your settings once (saved to `poc-results/campaign.env`), then shows a progress
board:

```
  1) [·] M0  Baseline — all logging OFF (start)
  2) [·] M1  Native QUERY logging only
  3) [·] M2  Native QUERY + RESPONSE logging
  4) [·] M3  dnstap → collector
  5) [·] M0' Baseline again — drift check (end)
  6) [·] Process results & build comparison
```

Pick a step (or `n` for next): the guide prints the **exact Grid Manager GUI change**, waits
for you to confirm it + the DNS restart, runs the load test, then records the step
`✓ DONE / ✗ FAILED / ⊘ SKIPPED` in `poc-results/campaign-progress.tsv`. Quit and resume any
time; re-run any step freely. The sections below document the individual scripts it calls.

## What the scripts do and don't do

- **Read-only** against the NIOS member and the collector. They do **not** change logging
  settings — you toggle the mode once in the Grid Manager GUI (doc §3.6) and *declare* it to
  the script so results are tagged. They drive load and record numbers.
- **Interactive:** each test prints **what it does** and asks before running; you can **skip**
  any test, **re-run** any test, run all pending, process results, or quit — from a menu that
  shows each test's latest status (— / PASS / FAIL).
- **Re-runnable by design:** results are **append-only** (one JSON line per run in
  `results.jsonl`). Re-running a test writes a *new* run number; the processor uses the
  **latest** run per (mode, test). So correcting a failed test = just run it again.

## Prerequisites

- A load generator on a **separate host** from the member: `dnsperf` (preferred) or
  `flamethrower`. The harness auto-detects which is installed.
- `python3` (used for parsing/verdicts/processing — stdlib only).
- Network path generator → member `:53`, and (dnstap mode) member → collector `:6001`.
- Optional: `snmpget` (net-snmp) to capture **server CPU + memory**. The Infoblox OIDs are
  **built in** (`IB-PLATFORMONE-MIB` / `ibSystemMonitor`) — just set `SNMP_COMMUNITY` and the
  member's SNMP ACL to allow the generator host. NIOS exposes CPU/mem via its enterprise MIB,
  not HOST-RESOURCES/UCD. See [`SNMP-Integration.md`](../../SNMP-Integration.md).

  | Metric | Object | OID (scalar, polled with `.0`) |
  |---|---|---|
  | CPU % | `ibSystemMonitorCpuUsage` | `1.3.6.1.4.1.7779.3.1.1.2.1.8.1.1.0` |
  | Memory % | `ibSystemMonitorMemUsage` | `1.3.6.1.4.1.7779.3.1.1.2.1.8.2.1.0` |
  | Swap % | `ibSystemMonitorSwapUsage` | `1.3.6.1.4.1.7779.3.1.1.2.1.8.3.1.0` |

  Override with `SNMP_CPU_OID` / `SNMP_MEM_OID` if your build differs. Without `SNMP_COMMUNITY`,
  CPU/mem are left blank and the rest of the test still runs.

## Query file

Plain dnsperf format — **one `qname qtype` per line, no comments** (`#` lines become invalid
queries). Prefer a file derived from a **real production capture** so the qtype mix and
cache hit/miss ratio are representative. For **authoritative** testing (recommended — removes
the cold-cache confound, doc §3.7) the names should be in a zone the member is authoritative
for. The harness records the file's sha256 so "same query file across all modes" is provable.

## Usage

```bash
export SERVER=10.20.30.40                         # the NIOS member under test
export QUERYFILE=./scripts/poc/queryfile.example  # your real query file
# dnstap mode also:
export COLLECTOR_METRICS_URL=http://172.25.15.234:9599/metrics
export JSONL_PATH=/var/log/dnscollector/dnscollector-events.jsonl   # if running ON the collector → enables bytes/event

# 1) Baseline + native logging modes (run baseline first, and again last for the drift check)
./scripts/poc/run_test_querylog.sh

# 2) dnstap mode
./scripts/poc/run_test_dnstap.sh

# 3) Build the comparison tables (or press 'p' inside either script)
python3 ./scripts/poc/process_results.py --results ./poc-results/results.jsonl
```

### Recommended run order (maps to doc §3.4)

1. `run_test_querylog.sh` → mode **1 (baseline)** → run **T3** (and **T2**). This is **M0**.
2. `run_test_querylog.sh` → mode **2 (queries-only)** → **T2/T3**. (**M1**)
3. `run_test_querylog.sh` → mode **3 (queries+responses)** → **T2/T3**. (**M2**)
4. `run_test_dnstap.sh` → **T2/T3** (+ **T7** safety). (**M3**)
5. `run_test_querylog.sh` → mode **1 (baseline)** again → **T3**. This is **M0'** (drift check).
6. Process results.

Between every mode switch: change the GUI setting, let DNS restart, and **re-warm** (the
harness warms automatically before each measured run — `WARMUP_SECONDS`, default 30s).

## Tunables (env vars)

| Var | Default | Meaning |
|---|---|---|
| `SERVER` / `PORT` | — / 53 | NIOS member under test |
| `QUERYFILE` | — | dnsperf query file (required) |
| `RESULTS_DIR` | `./poc-results` | where `results.jsonl` + raw outputs land |
| `QPS_STEADY` | 5000 | P1 steady rate for T3/T4 |
| `QPS_SWEEP` | `1000 2500 5000 10000 20000 40000` | T2 ramp steps |
| `RUN_SECONDS` / `SWEEP_SECONDS` / `SOAK_SECONDS` | 120 / 30 / 7200 | run durations |
| `WARMUP_SECONDS` | 30 | warm-up before each measured run (§3.7); 0 disables |
| `CLIENTS` / `THREADS` | 20 / nproc | dnsperf concurrency |
| `MAX_LOST_PCT` / `MIN_COMPLETED_PCT` | 1.0 / 99.0 | auto PASS/FAIL thresholds |
| `SNMP_COMMUNITY` | — | set to enable server CPU+mem capture (Infoblox OIDs built in) |
| `SNMP_CPU_OID` / `SNMP_MEM_OID` / `SNMP_HOST` | Infoblox `ibSystemMonitor` / `$SERVER` | override only if your build differs |
| `COLLECTOR_METRICS_URL` / `JSONL_PATH` | collector `:9599` / events.jsonl | dnstap capture |

## Output

- `poc-results/results.jsonl` — every run, append-only (the source of truth).
- `poc-results/raw/` — raw dnsperf/flame output per run (kept for manual inspection).
- `poc-results/results-summary.md` / `.csv` — written by the processor.

> **Percentiles:** classic `dnsperf` reports avg/min/max/stddev latency, not p95/p99. For
> percentile latency use `flamethrower`; the harness captures whatever the tool provides and
> the processor renders what's present.
