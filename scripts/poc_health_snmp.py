#!/usr/bin/env python3
"""poc_health_snmp.py — InfoBlox / host system-health collector for Splunk.

OPTIONAL add-on to the dnstap pipeline. Polls system-health metrics over SNMP
(CPU, memory, swap, disk, load, uptime — the same things the InfoBlox Grid
Manager "System" panel shows) and writes Splunk-friendly ``key=value`` lines to
a log file. A Splunk Universal Forwarder monitors that file and ships the lines
to ``index=mi_dhcp`` (``sourcetype=infoblox:health``, ``source=infoblox:health``)
alongside the dnstap data, where the ``infoblox_system_health`` dashboard renders
them as gauges and trends.

Two data sources:
  --target/--community : poll a remote SNMP agent (InfoBlox member or any host
                         running net-snmp). Shells out to ``snmpget`` (net-snmp),
                         so no Python SNMP dependency.
  --self               : read THIS host's metrics from /proc + statvfs (stdlib,
                         no SNMP). Use to monitor the collector box itself, and
                         for testing/verification without a live SNMP target.

Output is one line per poll, e.g.:
  2026-06-23T02:15:03Z member=infoblox-poc-01 cpu_used_pct=12.5 cpu_idle_pct=87.5
    mem_used_pct=43.1 mem_total_mb=32000 mem_used_mb=13792 swap_used_pct=2.1
    disk_used_pct=38.0 load1=0.42 load5=0.39 load15=0.35 uptime_s=864000
    health_status=OK
Splunk auto-extracts every ``key=value`` — no props/transforms required.

Examples:
  python3 scripts/poc_health_snmp.py --self --stdout                 # one sample to stdout
  python3 scripts/poc_health_snmp.py --self --out /var/log/dnstap-health/health.log --loop 30
  python3 scripts/poc_health_snmp.py --target 172.25.15.234 --community public \
      --member infoblox-poc-01 --out /var/log/dnstap-health/health.log --loop 60
"""
# NOTE: keep this Python 3.6 compatible (RHEL 7.9 stock python3) — no
# `from __future__ import annotations`, no builtin generics (list[...]), no
# `X | None` unions. stdlib only; SNMP is done by shelling to net-snmp.
import argparse
import os
import shutil
import subprocess
import sys
import time
from typing import Dict, List, Optional, Tuple

# ── SNMP OID map (numeric, so no MIB files need to be installed) ───────────
# Defaults are UCD-SNMP-MIB + HOST-RESOURCES-MIB, which InfoBlox NIOS and any
# net-snmp host answer. Every OID is overridable via the matching env var, so a
# build that prefers the InfoBlox enterprise MIB (IB-PLATFORMONE, .7779) can be
# pointed at its own leaves without code changes.
OIDS = {
    "cpu_idle":   os.environ.get("OID_CPU_IDLE",   ".1.3.6.1.4.1.2021.11.11.0"),   # ssCpuIdle %
    "mem_total":  os.environ.get("OID_MEM_TOTAL",  ".1.3.6.1.4.1.2021.4.5.0"),     # memTotalReal KB
    "mem_avail":  os.environ.get("OID_MEM_AVAIL",  ".1.3.6.1.4.1.2021.4.6.0"),     # memAvailReal KB
    "swap_total": os.environ.get("OID_SWAP_TOTAL", ".1.3.6.1.4.1.2021.4.3.0"),     # memTotalSwap KB
    "swap_avail": os.environ.get("OID_SWAP_AVAIL", ".1.3.6.1.4.1.2021.4.4.0"),     # memAvailSwap KB
    "disk_pct":   os.environ.get("OID_DISK_PCT",   ".1.3.6.1.4.1.2021.9.1.9.1"),   # dskPercent %
    "disk_total": os.environ.get("OID_DISK_TOTAL", ".1.3.6.1.4.1.2021.9.1.6.1"),   # dskTotal KB
    "disk_used":  os.environ.get("OID_DISK_USED",  ".1.3.6.1.4.1.2021.9.1.8.1"),   # dskUsed KB
    "load1":      os.environ.get("OID_LOAD1",      ".1.3.6.1.4.1.2021.10.1.3.1"),  # laLoad.1
    "load5":      os.environ.get("OID_LOAD5",      ".1.3.6.1.4.1.2021.10.1.3.2"),  # laLoad.2
    "load15":     os.environ.get("OID_LOAD15",     ".1.3.6.1.4.1.2021.10.1.3.3"),  # laLoad.3
    "uptime":     os.environ.get("OID_UPTIME",     ".1.3.6.1.2.1.25.1.1.0"),       # hrSystemUptime
}

# Field order for the emitted line (stable output for humans + tests).
LINE_FIELDS = [
    "cpu_used_pct", "cpu_idle_pct",
    "mem_used_pct", "mem_total_mb", "mem_used_mb",
    "swap_used_pct", "swap_total_mb", "swap_used_mb",
    "disk_used_pct", "disk_total_gb", "disk_used_gb",
    "load1", "load5", "load15",
    "uptime_s",
]


def _fnum(v: float, dp: int = 1) -> str:
    """Format a float with ``dp`` decimals, trimming a trailing .0 for ints."""
    return f"{v:.{dp}f}"


def derive_status(m: Dict[str, float], warn: float, crit: float) -> str:
    """OK / WARN / CRIT from the worst of cpu/mem/swap/disk usage — mirrors the
    green / yellow / red status the InfoBlox Grid Manager shows per node."""
    worst = 0.0
    for k in ("cpu_used_pct", "mem_used_pct", "swap_used_pct", "disk_used_pct"):
        if k in m:
            worst = max(worst, m[k])
    if worst >= crit:
        return "CRIT"
    if worst >= warn:
        return "WARN"
    return "OK"


# ── local (/proc) collection — no SNMP, for --self and tests ───────────────
def _read_proc_stat() -> Tuple[int, int]:
    """Return (idle_jiffies, total_jiffies) from the aggregate /proc/stat cpu."""
    with open("/proc/stat") as fh:
        for line in fh:
            if line.startswith("cpu "):
                parts = [int(x) for x in line.split()[1:]]
                idle = parts[3] + (parts[4] if len(parts) > 4 else 0)  # idle + iowait
                return idle, sum(parts)
    raise RuntimeError("no 'cpu ' line in /proc/stat")


def read_local_health(sample_s: float = 0.4) -> Dict[str, float]:
    """Collect this host's health from /proc + statvfs (stdlib only)."""
    m = {}  # type: Dict[str, float]

    # CPU: sample /proc/stat twice and diff
    idle0, total0 = _read_proc_stat()
    time.sleep(max(0.05, sample_s))
    idle1, total1 = _read_proc_stat()
    dt = (total1 - total0) or 1
    idle_pct = 100.0 * (idle1 - idle0) / dt
    m["cpu_idle_pct"] = round(max(0.0, min(100.0, idle_pct)), 1)
    m["cpu_used_pct"] = round(100.0 - m["cpu_idle_pct"], 1)

    # Memory + swap from /proc/meminfo (values in KB)
    info = {}  # type: Dict[str, int]
    with open("/proc/meminfo") as fh:
        for line in fh:
            k, _, rest = line.partition(":")
            info[k] = int(rest.strip().split()[0])
    mem_total = info.get("MemTotal", 0)
    mem_avail = info.get("MemAvailable", info.get("MemFree", 0))
    if mem_total:
        m["mem_total_mb"] = round(mem_total / 1024.0, 0)
        m["mem_used_mb"] = round((mem_total - mem_avail) / 1024.0, 0)
        m["mem_used_pct"] = round(100.0 * (mem_total - mem_avail) / mem_total, 1)
    sw_total = info.get("SwapTotal", 0)
    sw_free = info.get("SwapFree", 0)
    m["swap_total_mb"] = round(sw_total / 1024.0, 0)
    if sw_total:
        m["swap_used_mb"] = round((sw_total - sw_free) / 1024.0, 0)
        m["swap_used_pct"] = round(100.0 * (sw_total - sw_free) / sw_total, 1)
    else:
        m["swap_used_mb"] = 0.0
        m["swap_used_pct"] = 0.0

    # Disk: root filesystem via statvfs
    st = os.statvfs("/")
    total_b = st.f_blocks * st.f_frsize
    free_b = st.f_bfree * st.f_frsize
    used_b = total_b - free_b
    if total_b:
        m["disk_total_gb"] = round(total_b / (1024.0 ** 3), 1)
        m["disk_used_gb"] = round(used_b / (1024.0 ** 3), 1)
        m["disk_used_pct"] = round(100.0 * used_b / total_b, 1)

    # Load + uptime
    try:
        la = os.getloadavg()
        m["load1"], m["load5"], m["load15"] = round(la[0], 2), round(la[1], 2), round(la[2], 2)
    except (OSError, AttributeError):
        pass
    try:
        with open("/proc/uptime") as fh:
            m["uptime_s"] = round(float(fh.read().split()[0]), 0)
    except (OSError, ValueError):
        pass
    return m


# ── SNMP collection (shell out to net-snmp) ────────────────────────────────
def snmp_get(target: str, community: str, version: str, oids: List[str],
             timeout: int = 5, retries: int = 1) -> Dict[str, str]:
    """Run one ``snmpget`` for all OIDs; return numeric-OID -> raw value string.

    Uses ``-On -Oqv`` so output is value-only, in the same order as the OIDs we
    asked for — robust without MIB files installed. Missing OIDs come back as a
    sentinel and are dropped.
    """
    snmpget = shutil.which("snmpget")
    if not snmpget:
        raise RuntimeError("snmpget not found — install net-snmp-utils (RHEL) / snmp (Debian)")
    cmd = [snmpget, "-v", version, "-c", community,
           "-t", str(timeout), "-r", str(retries),
           "-On", "-Oqv", target] + oids
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)
    if proc.returncode != 0 and not proc.stdout.strip():
        raise RuntimeError("snmpget failed: " + (proc.stderr.strip() or "no output"))
    lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
    out = {}  # type: Dict[str, str]
    for oid, raw in zip(oids, lines):
        out[oid] = raw
    return out


def _to_float(raw: str) -> Optional[float]:
    """Parse a net-snmp value (may be quoted, have units, or be 'No Such ...')."""
    if not raw:
        return None
    s = raw.strip().strip('"')
    low = s.lower()
    if low.startswith("no such") or low.startswith("no more") or low == "":
        return None
    tok = s.split()[0]  # drop trailing units like 'KB' or 'seconds'
    try:
        return float(tok)
    except ValueError:
        return None


def parse_snmp_health(values: Dict[str, str]) -> Dict[str, float]:
    """Turn raw OID->string values into the normalized health metric dict."""
    g = {}  # type: Dict[str, float]
    for key, oid in OIDS.items():
        f = _to_float(values.get(oid, ""))
        if f is not None:
            g[key] = f

    m = {}  # type: Dict[str, float]
    if "cpu_idle" in g:
        m["cpu_idle_pct"] = round(g["cpu_idle"], 1)
        m["cpu_used_pct"] = round(100.0 - g["cpu_idle"], 1)
    if "mem_total" in g and g["mem_total"] > 0:
        avail = g.get("mem_avail", 0.0)
        m["mem_total_mb"] = round(g["mem_total"] / 1024.0, 0)
        m["mem_used_mb"] = round((g["mem_total"] - avail) / 1024.0, 0)
        m["mem_used_pct"] = round(100.0 * (g["mem_total"] - avail) / g["mem_total"], 1)
    if "swap_total" in g:
        st = g["swap_total"]
        m["swap_total_mb"] = round(st / 1024.0, 0)
        if st > 0:
            avail = g.get("swap_avail", 0.0)
            m["swap_used_mb"] = round((st - avail) / 1024.0, 0)
            m["swap_used_pct"] = round(100.0 * (st - avail) / st, 1)
        else:
            m["swap_used_mb"] = 0.0
            m["swap_used_pct"] = 0.0
    if "disk_pct" in g:
        m["disk_used_pct"] = round(g["disk_pct"], 1)
    if "disk_total" in g and g["disk_total"] > 0:
        m["disk_total_gb"] = round(g["disk_total"] / (1024.0 ** 2), 1)  # KB -> GB
        m["disk_used_gb"] = round(g.get("disk_used", 0.0) / (1024.0 ** 2), 1)
    for k in ("load1", "load5", "load15"):
        if k in g:
            m[k] = round(g[k], 2)
    if "uptime" in g:
        m["uptime_s"] = round(g["uptime"] / 100.0, 0)  # timeticks (1/100 s) -> s
    return m


# ── line formatting ────────────────────────────────────────────────────────
def format_line(metrics: Dict[str, float], member: str, ts: str,
                warn: float = 75.0, crit: float = 90.0) -> str:
    """Build the Splunk ``key=value`` line. Stable field order; status last."""
    parts = [f"{ts} member={member}"]
    for f in LINE_FIELDS:
        if f in metrics:
            dp = 2 if f.startswith("load") else (0 if f.endswith(("_mb", "_s")) else 1)
            parts.append(f"{f}={_fnum(metrics[f], dp)}")
    parts.append(f"health_status={derive_status(metrics, warn, crit)}")
    return " ".join(parts)


def iso_utc(epoch: Optional[float] = None) -> str:
    t = time.gmtime(epoch if epoch is not None else time.time())
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", t)


def collect_once(args: argparse.Namespace) -> str:
    if args.self_host:
        metrics = read_local_health()
    else:
        raw = snmp_get(args.target, args.community, args.version,
                       list(OIDS.values()), timeout=args.timeout, retries=args.retries)
        metrics = parse_snmp_health(raw)
    return format_line(metrics, args.member, iso_utc(), warn=args.warn, crit=args.crit)


def _write_line(line: str, out_path: Optional[str], to_stdout: bool) -> None:
    if out_path:
        d = os.path.dirname(out_path)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(out_path, "a") as fh:
            fh.write(line + "\n")
    if to_stdout or not out_path:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="InfoBlox/host system-health -> Splunk key=value lines")
    src = p.add_argument_group("source")
    src.add_argument("--self", dest="self_host", action="store_true",
                     help="read THIS host's metrics from /proc (no SNMP)")
    src.add_argument("--target", help="SNMP agent host/IP (InfoBlox member or any net-snmp host)")
    src.add_argument("--community", default=os.environ.get("SNMP_COMMUNITY", "public"),
                     help="SNMPv2c community (default: public / $SNMP_COMMUNITY)")
    src.add_argument("--version", default="2c", choices=["1", "2c"],
                     help="SNMP version (default: 2c)")
    src.add_argument("--timeout", type=int, default=5, help="snmpget timeout seconds")
    src.add_argument("--retries", type=int, default=1, help="snmpget retries")
    out = p.add_argument_group("output")
    out.add_argument("--member", default=os.environ.get("HEALTH_MEMBER", ""),
                     help="member/node label for the line (default: hostname of target/self)")
    out.add_argument("--out", help="append lines to this file (UF monitors it)")
    out.add_argument("--stdout", action="store_true", help="also echo to stdout when --out is set")
    out.add_argument("--loop", type=int, metavar="SECONDS",
                     help="poll forever every SECONDS (default: one sample then exit)")
    out.add_argument("--warn", type=float, default=75.0, help="WARN threshold %% (default 75)")
    out.add_argument("--crit", type=float, default=90.0, help="CRIT threshold %% (default 90)")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.self_host and not args.target:
        sys.stderr.write("ERROR: pass --self or --target <host>\n")
        return 2
    if not args.member:
        args.member = args.target if args.target else _hostname()

    def _one() -> int:
        try:
            line = collect_once(args)
        except Exception as exc:  # noqa: BLE001 — collector must not crash the loop
            sys.stderr.write(f"health poll error: {exc}\n")
            return 1
        _write_line(line, args.out, args.stdout)
        return 0

    if args.loop:
        sys.stderr.write(f"health collector: every {args.loop}s -> {args.out or 'stdout'}\n")
        while True:
            _one()
            time.sleep(args.loop)
    return _one()


def _hostname() -> str:
    try:
        import socket
        return socket.gethostname()
    except Exception:  # noqa: BLE001
        return "localhost"


if __name__ == "__main__":
    sys.exit(main())
