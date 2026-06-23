#!/usr/bin/env python3
"""poc_health_snmp.py — InfoBlox / host system-health collector for Splunk.

OPTIONAL add-on to the dnstap pipeline. Polls system health over SNMP and writes
Splunk-friendly ``key=value`` lines that a Splunk Universal Forwarder ships to
``index=mi_dhcp`` (``sourcetype=infoblox:health``, ``source=infoblox:health``),
where the ``infoblox_system_health`` dashboard renders them. dnstap answers "who
queried what"; this answers "is the member healthy and are its services up" —
the gap dnstap can't see.

Three sources / profiles:
  --self                       read THIS host's metrics from /proc + statvfs (no
                               SNMP). Monitors the collector box; used for tests.
  --target H --profile infoblox  (DEFAULT for --target) poll an InfoBlox member
                               via its enterprise MIB (.7779): CPU/mem/swap %,
                               per-service status (dns/dhcp/ntp/cache-accel/…),
                               CPU temperature, replication & HA status.
  --target H --profile ucd     poll a generic net-snmp host (UCD-SNMP-MIB +
                               HOST-RESOURCES-MIB): CPU/mem/swap/disk/load/uptime.

Fleet mode:
  --targets-file FILE          one member per line: ``host[,community[,member[,profile]]]``
                               (``#`` comments / blanks ignored). One line emitted
                               per member each cycle — point it at every DNS server
                               that sends dnstap.

DNS query rate / latency are intentionally NOT collected here — dnstap already
provides them. SNMP is used only for resource + service + hardware health.

Examples:
  python3 scripts/poc_health_snmp.py --self --stdout
  python3 scripts/poc_health_snmp.py --target 172.25.15.234 --community public --stdout
  python3 scripts/poc_health_snmp.py --targets-file /etc/dnstap-health/targets.csv \
      --out /var/log/dnstap-health/health.log --loop 60
"""
# NOTE: keep this Python 3.6 compatible (RHEL 7.9 stock python3) — no
# `from __future__ import annotations`, no builtin generics (list[...]), no
# `X | None` unions. stdlib only; SNMP is done by shelling to net-snmp.
import argparse
import os
import shutil
import socket
import subprocess
import sys
import time
from typing import Dict, List, Optional, Tuple

# ── Generic host OIDs (UCD-SNMP-MIB + HOST-RESOURCES-MIB) ───────────────────
# Used by --profile ucd; answered by any net-snmp host (and the collector box).
# Every OID is overridable via the matching env var.
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

# ── InfoBlox enterprise MIB (IB-PLATFORMONE-MIB, .7779) ─────────────────────
# Confirmed against the field-tested check_infoblox tool + the published MIB.
IB_BASE = os.environ.get("OID_IB_BASE", ".1.3.6.1.4.1.7779.3.1.1.2.1")
IB_SYSMON = IB_BASE + ".8"          # .8.1=cpu .8.2=mem .8.3=swap usage (%)
IB_CPU_TEMP = os.environ.get("OID_IB_CPU_TEMP", IB_BASE + ".1.0")   # ibCPUTemperature (string)
IB_REPL_STATUS = IB_BASE + ".2.1.2"  # ibNodeReplicationStatus (table column, string)
IB_HA_STATUS = os.environ.get("OID_IB_HA", IB_BASE + ".13.0")       # HA Active/Passive
IB_SVC_NAME = IB_BASE + ".9.1.1"     # ibServiceName  (enum)
IB_SVC_STATUS = IB_BASE + ".9.1.2"   # ibServiceStatus (enum)
SYS_UPTIME = ".1.3.6.1.2.1.1.3.0"    # sysUpTime (standard MIB-II, always present)

# ibServiceName enum -> name (IB-PLATFORMONE-MIB IbServiceNames)
IB_SERVICE_NAMES = {
    1: "dhcp", 2: "dns", 3: "ntp", 4: "tftp", 5: "http-file-dist", 6: "ftp",
    7: "bloxtools-move", 8: "bloxtools", 9: "node-status", 10: "disk-usage",
    11: "enet-lan", 12: "enet-lan2", 13: "enet-ha", 14: "enet-mgmt", 15: "lcd",
    16: "memory", 17: "replication", 18: "db-object", 19: "raid-summary",
    20: "raid-disk1", 21: "raid-disk2", 22: "raid-disk3", 23: "raid-disk4",
    24: "raid-disk5", 25: "raid-disk6", 26: "raid-disk7", 27: "raid-disk8",
    28: "fan1", 29: "fan2", 30: "fan3", 31: "fan4", 32: "fan5", 33: "fan6",
    34: "fan7", 35: "fan8", 36: "power-supply1", 37: "power-supply2",
    38: "ntp-sync", 39: "cpu1-temp", 40: "cpu2-temp", 41: "sys-temp",
    42: "raid-battery", 43: "cpu-usage", 44: "ospf", 45: "bgp", 46: "mgm-service",
    47: "subgrid-conn", 48: "network-capacity", 49: "reporting",
    50: "dns-cache-acceleration", 51: "ospf6", 52: "swap-usage",
    53: "discovery-consolidator", 54: "discovery-collector",
    55: "discovery-capacity", 56: "threat-protection", 57: "cloud-api",
    58: "threat-analytics", 59: "taxii", 60: "bfd", 61: "outbound",
}
# ibServiceStatus enum -> label (IbServiceStates)
IB_SERVICE_STATES = {1: "working", 2: "warning", 3: "failed", 4: "inactive", 5: "unknown"}

# Numeric fields, in stable line order (only those present are emitted).
LINE_FIELDS = [
    "cpu_used_pct", "cpu_idle_pct", "cpu_temp_c",
    "mem_used_pct", "mem_total_mb", "mem_used_mb",
    "swap_used_pct", "swap_total_mb", "swap_used_mb",
    "disk_used_pct", "disk_total_gb", "disk_used_gb",
    "load1", "load5", "load15",
    "uptime_s",
    "services_failed", "services_warning",
]
# Text (string-valued) fields, emitted after the numerics. svc_* are appended
# dynamically and sorted.
TEXT_FIELDS = ["repl_status", "ha_status"]


def _fnum(v: float, dp: int = 1) -> str:
    return f"{v:.{dp}f}"


def _dp_for(field: str) -> int:
    if field.startswith("load"):
        return 2
    if field.endswith(("_mb", "_s")) or field in ("services_failed", "services_warning",
                                                   "dns_lat_nonaa_1m_us", "dns_lat_aa_1m_us"):
        return 0
    return 1


def derive_status(m: Dict[str, float], warn: float, crit: float) -> str:
    """OK / WARN / CRIT — worst of resource usage AND service health. Mirrors the
    green / yellow / red status the InfoBlox Grid Manager shows per node."""
    if m.get("services_failed", 0) >= 1:
        return "CRIT"
    worst = 0.0
    for k in ("cpu_used_pct", "mem_used_pct", "swap_used_pct", "disk_used_pct"):
        if k in m:
            worst = max(worst, m[k])
    if worst >= crit:
        return "CRIT"
    if worst >= warn or m.get("services_warning", 0) >= 1:
        return "WARN"
    return "OK"


# ── local (/proc) collection — no SNMP, for --self and tests ───────────────
def _read_proc_stat() -> Tuple[int, int]:
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
    idle0, total0 = _read_proc_stat()
    time.sleep(max(0.05, sample_s))
    idle1, total1 = _read_proc_stat()
    dt = (total1 - total0) or 1
    idle_pct = 100.0 * (idle1 - idle0) / dt
    m["cpu_idle_pct"] = round(max(0.0, min(100.0, idle_pct)), 1)
    m["cpu_used_pct"] = round(100.0 - m["cpu_idle_pct"], 1)

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

    st = os.statvfs("/")
    total_b = st.f_blocks * st.f_frsize
    used_b = total_b - st.f_bfree * st.f_frsize
    if total_b:
        m["disk_total_gb"] = round(total_b / (1024.0 ** 3), 1)
        m["disk_used_gb"] = round(used_b / (1024.0 ** 3), 1)
        m["disk_used_pct"] = round(100.0 * used_b / total_b, 1)

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


# ── SNMP plumbing (shell out to net-snmp) ──────────────────────────────────
def _snmp_base(tool: str, target: str, community: str, version: str,
               timeout: int, retries: int) -> List[str]:
    path = shutil.which(tool)
    if not path:
        raise RuntimeError(f"{tool} not found — install net-snmp-utils (RHEL) / snmp (Debian)")
    return [path, "-v", version, "-c", community, "-t", str(timeout), "-r", str(retries), "-On"]


def snmp_get(target: str, community: str, version: str, oids: List[str],
             timeout: int = 5, retries: int = 1) -> Dict[str, str]:
    """One snmpget for all OIDs (-Oqv, value-only, in request order)."""
    cmd = _snmp_base("snmpget", target, community, version, timeout, retries)
    cmd += ["-Oqv", target] + oids
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)
    if proc.returncode != 0 and not proc.stdout.strip():
        raise RuntimeError("snmpget failed: " + (proc.stderr.strip() or "no output"))
    lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
    out = {}  # type: Dict[str, str]
    for oid, raw in zip(oids, lines):
        out[oid] = raw
    return out


def snmp_walk(target: str, community: str, version: str, oid: str,
              timeout: int = 5, retries: int = 1) -> List[Tuple[str, str]]:
    """snmpwalk a subtree; return [(numeric_oid, value), …] (-Oqn = oid + value)."""
    cmd = _snmp_base("snmpwalk", target, community, version, timeout, retries)
    cmd += ["-Oqn", target, oid]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)
    rows = []  # type: List[Tuple[str, str]]
    for ln in proc.stdout.splitlines():
        ln = ln.strip()
        if not ln or " " not in ln:
            continue
        k, _, v = ln.partition(" ")
        rows.append((k, v.strip()))
    return rows


def _to_float(raw: str) -> Optional[float]:
    """Parse a net-snmp value (may be quoted, have units, or be 'No Such …')."""
    if not raw:
        return None
    s = raw.strip().strip('"')
    low = s.lower()
    if low.startswith("no such") or low.startswith("no more") or s == "":
        return None
    tok = s.split()[0]
    try:
        return float(tok)
    except ValueError:
        return None


def _first_int(s: str) -> Optional[int]:
    """First integer found in a string (e.g. 'CPU_TEMP: 36 C' -> 36)."""
    cur = ""
    for ch in s:
        if ch.isdigit() or (ch == "-" and not cur):
            cur += ch
        elif cur:
            break
    try:
        return int(cur)
    except ValueError:
        return None


# ── UCD / HOST-RESOURCES profile (generic hosts, --self schema parity) ─────
def parse_snmp_health(values: Dict[str, str]) -> Dict[str, float]:
    """Raw OID->string (UCD/HOST-RESOURCES) -> normalized metric dict."""
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
        m["disk_total_gb"] = round(g["disk_total"] / (1024.0 ** 2), 1)
        m["disk_used_gb"] = round(g.get("disk_used", 0.0) / (1024.0 ** 2), 1)
    for k in ("load1", "load5", "load15"):
        if k in g:
            m[k] = round(g[k], 2)
    if "uptime" in g:
        m["uptime_s"] = round(g["uptime"] / 100.0, 0)
    return m


def collect_ucd(target: str, community: str, version: str,
                timeout: int, retries: int) -> Tuple[Dict[str, float], Dict[str, str]]:
    raw = snmp_get(target, community, version, list(OIDS.values()), timeout, retries)
    return parse_snmp_health(raw), {}


# ── InfoBlox enterprise profile (the dnstap-sending members) ───────────────
def parse_ib_services(name_rows: List[Tuple[str, str]],
                      status_rows: List[Tuple[str, str]]) -> Tuple[Dict[str, str], int, int]:
    """Pair ibServiceName + ibServiceStatus walks by table index.

    Returns (svc_<name>=<state> dict, failed_count, warning_count). inactive(4)
    and unknown(5) are NOT counted as bad — a member legitimately runs a subset
    of services (e.g. dhcp inactive on a DNS-only member)."""
    def _idx(oid: str, col: str) -> str:
        i = oid.find(col)
        return oid[i + len(col):].lstrip(".") if i >= 0 else oid

    names = {}  # type: Dict[str, int]
    for oid, val in name_rows:
        n = _to_float(val)
        if n is not None:
            names[_idx(oid, IB_SVC_NAME)] = int(n)
    text = {}  # type: Dict[str, str]
    failed = warning = 0
    for oid, val in status_rows:
        s = _to_float(val)
        if s is None:
            continue
        idx = _idx(oid, IB_SVC_STATUS)
        sint = int(s)
        nm = IB_SERVICE_NAMES.get(names.get(idx, -1), "svc" + idx)
        text["svc_" + nm.replace("-", "_")] = IB_SERVICE_STATES.get(sint, str(sint))
        if sint == 3:
            failed += 1
        elif sint == 2:
            warning += 1
    return text, failed, warning


def collect_infoblox(target: str, community: str, version: str,
                     timeout: int, retries: int) -> Tuple[Dict[str, float], Dict[str, str]]:
    m = {}  # type: Dict[str, float]
    text = {}  # type: Dict[str, str]

    # CPU/mem/swap usage % — walk the system-monitor subtree (handles whatever
    # instance suffix the agent uses: .8.1.x cpu, .8.2.x mem, .8.3.x swap).
    for oid, val in snmp_walk(target, community, version, IB_SYSMON, timeout, retries):
        f = _to_float(val)
        if f is None:
            continue
        if ".8.1." in oid and "cpu_used_pct" not in m:
            m["cpu_used_pct"] = round(f, 1)
            m["cpu_idle_pct"] = round(100.0 - f, 1)
        elif ".8.2." in oid and "mem_used_pct" not in m:
            m["mem_used_pct"] = round(f, 1)
        elif ".8.3." in oid and "swap_used_pct" not in m:
            m["swap_used_pct"] = round(f, 1)

    # scalars: cpu temperature, HA, uptime (sysUpTime always present)
    scalars = snmp_get(target, community, version,
                       [IB_CPU_TEMP, IB_HA_STATUS, SYS_UPTIME], timeout, retries)
    temp = scalars.get(IB_CPU_TEMP, "")
    if temp:
        t = _first_int(temp)
        if t is not None:
            m["cpu_temp_c"] = float(t)
    ha = scalars.get(IB_HA_STATUS, "").strip().strip('"')
    if ha and not ha.lower().startswith("no such"):
        text["ha_status"] = ha
    up = _to_float(scalars.get(SYS_UPTIME, ""))
    if up is not None:
        m["uptime_s"] = round(up / 100.0, 0)

    # replication status (table column; take the first row)
    for _oid, val in snmp_walk(target, community, version, IB_REPL_STATUS, timeout, retries):
        v = val.strip().strip('"')
        if v and not v.lower().startswith("no such"):
            text["repl_status"] = v
            break

    # per-service status (the InfoBlox node view)
    names = snmp_walk(target, community, version, IB_SVC_NAME, timeout, retries)
    stats = snmp_walk(target, community, version, IB_SVC_STATUS, timeout, retries)
    svc, failed, warning = parse_ib_services(names, stats)
    text.update(svc)
    m["services_failed"] = float(failed)
    m["services_warning"] = float(warning)
    return m, text


# ── line formatting ────────────────────────────────────────────────────────
def format_line(metrics: Dict[str, float], member: str, ts: str,
                text: Optional[Dict[str, str]] = None,
                warn: float = 75.0, crit: float = 90.0) -> str:
    """Build the Splunk ``key=value`` line. Numerics first (stable order), then
    text/service fields (sorted), status last."""
    parts = [f"{ts} member={member}"]
    for f in LINE_FIELDS:
        if f in metrics:
            parts.append(f"{f}={_fnum(metrics[f], _dp_for(f))}")
    if text:
        ordered = [k for k in TEXT_FIELDS if k in text]
        ordered += sorted(k for k in text if k.startswith("svc_"))
        for k in ordered:
            v = str(text[k]).replace(" ", "_").strip('"')
            parts.append(f"{k}={v}")
    parts.append(f"health_status={derive_status(metrics, warn, crit)}")
    return " ".join(parts)


def iso_utc(epoch: Optional[float] = None) -> str:
    t = time.gmtime(epoch if epoch is not None else time.time())
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", t)


# ── target dispatch ────────────────────────────────────────────────────────
def collect_target_line(host: str, community: str, version: str, member: str,
                        profile: str, timeout: int, retries: int,
                        warn: float, crit: float, self_host: bool = False) -> str:
    if self_host:
        metrics, text = read_local_health(), {}  # type: Tuple[Dict[str, float], Dict[str, str]]
    elif profile == "ucd":
        metrics, text = collect_ucd(host, community, version, timeout, retries)
    else:
        metrics, text = collect_infoblox(host, community, version, timeout, retries)
    return format_line(metrics, member, iso_utc(), text=text, warn=warn, crit=crit)


def _read_targets(path: str, default_community: str, default_profile: str) -> List[Dict[str, str]]:
    """Parse a targets file: host[,community[,member[,profile]]] per line."""
    out = []  # type: List[Dict[str, str]]
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            f = [x.strip() for x in line.split(",")]
            host = f[0]
            out.append({
                "host": host,
                "community": f[1] if len(f) > 1 and f[1] else default_community,
                "member": f[2] if len(f) > 2 and f[2] else host,
                "profile": f[3] if len(f) > 3 and f[3] else default_profile,
            })
    return out


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
    src.add_argument("--target", help="SNMP agent host/IP (a single InfoBlox member or host)")
    src.add_argument("--targets-file",
                     help="file of host[,community[,member[,profile]]] lines (fleet)")
    src.add_argument("--community", default=os.environ.get("SNMP_COMMUNITY", "public"),
                     help="SNMPv2c community (default: public / $SNMP_COMMUNITY)")
    src.add_argument("--version", default="2c", choices=["1", "2c"], help="SNMP version")
    src.add_argument("--profile", default=os.environ.get("HEALTH_PROFILE", "infoblox"),
                     choices=["infoblox", "ucd"],
                     help="infoblox = enterprise MIB (default); ucd = generic net-snmp")
    src.add_argument("--timeout", type=int, default=5, help="snmp timeout seconds")
    src.add_argument("--retries", type=int, default=1, help="snmp retries")
    out = p.add_argument_group("output")
    out.add_argument("--member", default=os.environ.get("HEALTH_MEMBER", ""),
                     help="member/node label (default: target host or hostname)")
    out.add_argument("--out", help="append lines to this file (UF monitors it)")
    out.add_argument("--stdout", action="store_true", help="also echo to stdout when --out is set")
    out.add_argument("--loop", type=int, metavar="SECONDS", help="poll forever every SECONDS")
    out.add_argument("--warn", type=float, default=75.0, help="WARN threshold %% (default 75)")
    out.add_argument("--crit", type=float, default=90.0, help="CRIT threshold %% (default 90)")
    return p


def _hostname() -> str:
    try:
        return socket.gethostname()
    except OSError:
        return "localhost"


def _poll_cycle(args: argparse.Namespace) -> int:
    """One full pass (one line per target). Returns count of failed targets."""
    failures = 0
    if args.targets_file:
        targets = _read_targets(args.targets_file, args.community, args.profile)
        if not targets:
            sys.stderr.write(f"no targets in {args.targets_file}\n")
            return 1
        for t in targets:
            try:
                line = collect_target_line(t["host"], t["community"], args.version,
                                           t["member"], t["profile"], args.timeout,
                                           args.retries, args.warn, args.crit)
                _write_line(line, args.out, args.stdout)
            except Exception as exc:  # noqa: BLE001 — one bad member must not stop the rest
                sys.stderr.write(f"health poll error [{t['host']}]: {exc}\n")
                failures += 1
        return failures
    # single target or --self
    try:
        line = collect_target_line(args.target or "", args.community, args.version,
                                   args.member, args.profile, args.timeout, args.retries,
                                   args.warn, args.crit, self_host=args.self_host)
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"health poll error: {exc}\n")
        return 1
    _write_line(line, args.out, args.stdout)
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.self_host and not args.target and not args.targets_file:
        sys.stderr.write("ERROR: pass --self, --target <host>, or --targets-file <file>\n")
        return 2
    if not args.member:
        args.member = args.target if args.target else _hostname()

    if args.loop:
        dest = args.out or "stdout"
        sys.stderr.write(f"health collector: profile={args.profile} every {args.loop}s -> {dest}\n")
        while True:
            _poll_cycle(args)
            time.sleep(args.loop)
    return 1 if _poll_cycle(args) else 0


if __name__ == "__main__":
    sys.exit(main())
