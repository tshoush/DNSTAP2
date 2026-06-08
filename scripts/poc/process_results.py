#!/usr/bin/env python3
"""process_results.py — turn the POC harness's results.jsonl into the comparison tables.

Reads the append-only results log written by run_test_dnstap.sh / run_test_querylog.sh
(one JSON object per run) and produces, per the methodology in
docs/dnstap-value-evidence.md §4:

  * T1  baseline drift check          (first M0 vs last M0 — must agree)
  * T2  max sustainable QPS per mode  (highest sweep step still meeting SLA)
  * T3  fixed-load latency / CPU / disk / collector capture per mode
  * Storage  bytes/event + GB/day projection (from dnstap collector capture)

Because runs are append-only, a test that was re-run several times has multiple entries;
by default the LATEST run per (mode, test, profile) wins (so re-running a failed test and
then succeeding gives the right answer). Use --all to see every run.

Stdlib only. Outputs Markdown to stdout and, unless --no-write, also writes
results-summary.md / results-summary.csv next to the results log.

Usage:
  python3 process_results.py --results ./poc-results/results.jsonl
  python3 process_results.py --results ./poc-results/results.jsonl --all
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

# bytes/event compression ratio measured in the lab (docs §6); used only to annotate
# the storage projection until the real dnstap run supplies its own bytes/event.
GZIP_RATIO = 54.7

MODE_ORDER = ["M0_baseline", "M1_native_q", "M2_native_qr", "M3_dnstap"]
MODE_LABEL = {
    "M0_baseline": "M0 baseline (off)",
    "M1_native_q": "M1 native queries-only",
    "M2_native_qr": "M2 native queries+responses",
    "M3_dnstap": "M3 dnstap",
}


def load_runs(path: Path) -> list[dict]:
    runs = []
    with path.open() as fh:
        for n, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                runs.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"# warning: skipping malformed line {n}: {e}", file=sys.stderr)
    return runs


def latest_per(runs, keyfields):
    """Keep only the highest-run entry per key tuple."""
    best = {}
    for r in runs:
        key = tuple(r.get(k) for k in keyfields)
        cur = best.get(key)
        if cur is None or r.get("run", 0) >= cur.get("run", 0):
            best[key] = r
    return best


def fmt(v, nd=2, suffix=""):
    if v is None:
        return "—"
    try:
        return f"{float(v):.{nd}f}{suffix}"
    except (TypeError, ValueError):
        return str(v)


def mode_sort(m):
    return MODE_ORDER.index(m) if m in MODE_ORDER else 99


# --------------------------------------------------------------------------- tables
def table_drift(runs) -> str:
    """First vs last M0_baseline run — the temporal-drift gate (§3.2)."""
    m0 = sorted([r for r in runs if r.get("mode") == "M0_baseline" and r.get("test") == "T3"],
                key=lambda r: (r.get("ts", ""), r.get("run", 0)))
    out = ["## T1 — Baseline drift check (M0 start vs end)", ""]
    if len(m0) < 2:
        out += [f"_Need ≥2 M0_baseline T3 runs for a drift check (have {len(m0)}). "
                "Run the baseline at the start and again at the end._", ""]
        return "\n".join(out)
    a, b = m0[0], m0[-1]
    am, bm = a["metrics"], b["metrics"]
    out += ["| Metric | M0 (start) | M0' (end) | Δ |",
            "|---|---|---|---|"]
    for label, key, nd in [("QPS", "qps", 1), ("avg latency (s)", "avg_latency_s", 4),
                           ("lost %", "lost_pct", 2)]:
        av, bv = am.get(key), bm.get(key)
        delta = "—"
        if isinstance(av, (int, float)) and isinstance(bv, (int, float)):
            delta = f"{(bv - av):+.4f}" if nd >= 4 else f"{(bv - av):+.2f}"
        out.append(f"| {label} | {fmt(av, nd)} | {fmt(bv, nd)} | {delta} |")
    out += ["", "_If Δ is large, temporal drift occurred — investigate before trusting other deltas._", ""]
    return "\n".join(out)


def table_ceiling(runs) -> str:
    """T2: per mode, the highest sweep step that still PASSed."""
    out = ["## T2 — Max sustainable QPS per mode", "",
           "| Mode | Max QPS (last PASS step) | vs. baseline |", "|---|---|---|"]
    # latest run per (mode, qps step)
    best = latest_per([r for r in runs if r.get("test") == "T2"],
                      ["mode", "test", "profile"])
    # but T2 has many qps steps under same profile -> use per (mode, qps)
    by_mode_qps = {}
    for r in runs:
        if r.get("test") != "T2":
            continue
        qps = (r.get("params") or {}).get("qps")
        key = (r["mode"], qps)
        cur = by_mode_qps.get(key)
        if cur is None or r.get("run", 0) >= cur.get("run", 0):
            by_mode_qps[key] = r
    ceil = {}
    for (mode, qps), r in by_mode_qps.items():
        if r.get("status") == "PASS" and qps is not None:
            ceil[mode] = max(ceil.get(mode, 0), qps)
    base = ceil.get("M0_baseline")
    for mode in sorted(ceil, key=mode_sort):
        mx = ceil[mode]
        vs = "—"
        if base and mode != "M0_baseline":
            vs = f"{(mx - base) / base * 100:+.0f}%"
        elif mode == "M0_baseline":
            vs = "(reference)"
        out.append(f"| {MODE_LABEL.get(mode, mode)} | {mx} | {vs} |")
    if not ceil:
        out.append("| _no T2 runs yet_ | — | — |")
    out.append("")
    return "\n".join(out)


def table_fixedload(runs) -> str:
    """T3: latency / CPU / disk / collector per mode (latest run each)."""
    out = ["## T3 — Fixed-load latency / CPU / mem / collector (P1 steady)", "",
           "| Mode | QPS | avg lat (s) | max lat (s) | lost % | CPU avg% | CPU max% | mem avg% | events/s | bytes/event |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    best = latest_per([r for r in runs if r.get("test") == "T3"], ["mode"])
    for key in sorted(best, key=lambda k: mode_sort(k[0])):
        mode = key[0]
        r = best[key]
        m = r.get("metrics", {})
        # server_util (new) or server_cpu_pct (older runs) for back-compat
        su = r.get("server_util") or r.get("server_cpu_pct") or {}
        coll = r.get("collector") or {}
        out.append("| {mode} | {qps} | {avg} | {mx} | {lost} | {cpu} | {cmax} | {mem} | {eps} | {bpe} |".format(
            mode=MODE_LABEL.get(mode, mode),
            qps=fmt(m.get("qps"), 0),
            avg=fmt(m.get("avg_latency_s"), 4),
            mx=fmt(m.get("max_latency_s"), 4),
            lost=fmt(m.get("lost_pct"), 2),
            cpu=fmt(su.get("cpu_avg", su.get("avg")), 1) if su else "—",
            cmax=fmt(su.get("cpu_max", su.get("max")), 1) if su else "—",
            mem=fmt(su.get("mem_avg"), 1) if su else "—",
            eps=fmt(coll.get("events_per_s"), 0) if coll else "—",
            bpe=fmt(coll.get("bytes_per_event"), 0) if coll else "—",
        ))
    if not best:
        out.append("| _no T3 runs yet_ |" + " — |" * 9)
    out.append("")
    return "\n".join(out)


def table_storage(runs) -> str:
    """Storage projection from the dnstap T3 collector capture."""
    best = latest_per([r for r in runs if r.get("test") == "T3" and r.get("mode") == "M3_dnstap"],
                      ["mode"])
    out = ["## Storage projection (from dnstap capture)", ""]
    r = best.get(("M3_dnstap",))
    coll = (r or {}).get("collector") or {}
    bpe = coll.get("bytes_per_event")
    eps = coll.get("events_per_s")
    if not bpe or not eps:
        out += ["_No dnstap collector capture with bytes/event yet (run T3 in dnstap mode with "
                "JSONL locally readable)._", ""]
        return "\n".join(out)
    raw_day = bpe * eps * 86400 / 1e9
    gz_day = raw_day / GZIP_RATIO
    out += [f"Measured: **{bpe:.0f} bytes/event** at **{eps:.0f} events/s**.", "",
            "| | raw | gzip (~{:.0f}×) |".format(GZIP_RATIO),
            "|---|---|---|",
            f"| GB/day | {raw_day:.1f} | {gz_day:.2f} |",
            f"| GB/30d | {raw_day*30:.0f} | {gz_day*30:.1f} |",
            f"| TB/year | {raw_day*365/1000:.2f} | {gz_day*365/1000:.2f} |",
            "",
            "_Feed bytes/event back into docs/dnstap-collector-sizing.md §1._", ""]
    return "\n".join(out)


def table_allruns_csv(runs, csv_path: Path):
    cols = ["ts", "mode", "test", "profile", "run", "status", "qps", "avg_latency_s",
            "max_latency_s", "lost_pct", "completed_pct", "cpu_avg", "cpu_max", "mem_avg",
            "events_per_s", "bytes_per_event"]
    with csv_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for r in sorted(runs, key=lambda r: (mode_sort(r.get("mode", "")), r.get("test", ""), r.get("run", 0))):
            m = r.get("metrics", {})
            su = r.get("server_util") or r.get("server_cpu_pct") or {}
            coll = r.get("collector") or {}
            w.writerow([
                r.get("ts"), r.get("mode"), r.get("test"), r.get("profile"), r.get("run"),
                r.get("status"), m.get("qps"), m.get("avg_latency_s"), m.get("max_latency_s"),
                m.get("lost_pct"), m.get("completed_pct"),
                su.get("cpu_avg", su.get("avg")), su.get("cpu_max", su.get("max")), su.get("mem_avg"),
                (coll or {}).get("events_per_s"), (coll or {}).get("bytes_per_event"),
            ])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results", required=True, help="path to results.jsonl")
    ap.add_argument("--all", action="store_true", help="list every run, not just the latest")
    ap.add_argument("--no-write", action="store_true", help="don't write summary files")
    args = ap.parse_args()

    path = Path(args.results)
    if not path.is_file():
        print(f"error: results file not found: {path}", file=sys.stderr)
        return 2
    runs = load_runs(path)
    if not runs:
        print("No runs recorded yet.", file=sys.stderr)
        return 0

    sections = [
        f"# DNSTAP2 POC results — {len(runs)} runs from `{path.name}`",
        "",
        table_drift(runs),
        table_ceiling(runs),
        table_fixedload(runs),
        table_storage(runs),
    ]
    if args.all:
        sections.append("## All runs")
        sections.append("| mode | test | profile | run | status | qps | avg lat | lost% |")
        sections.append("|---|---|---|---|---|---|---|---|")
        for r in sorted(runs, key=lambda r: (mode_sort(r.get("mode", "")), r.get("test", ""), r.get("run", 0))):
            m = r.get("metrics", {})
            sections.append("| {} | {} | {} | {} | {} | {} | {} | {} |".format(
                r.get("mode"), r.get("test"), r.get("profile"), r.get("run"), r.get("status"),
                fmt(m.get("qps"), 0), fmt(m.get("avg_latency_s"), 4), fmt(m.get("lost_pct"), 2)))
        sections.append("")

    report = "\n".join(sections)
    print(report)

    if not args.no_write:
        md = path.with_name("results-summary.md")
        md.write_text(report + "\n")
        table_allruns_csv(runs, path.with_name("results-summary.csv"))
        print(f"\n# wrote {md} and {md.with_suffix('.csv').name}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
