"""Tests for the SNMP system-health collector (scripts/poc_health_snmp.py).

The SNMP path is exercised by feeding parse_snmp_health() captured net-snmp
values (no live agent needed); the local path is exercised against this host's
real /proc. format_line() and derive_status() are pinned so the Splunk
``key=value`` contract the dashboard depends on can't silently drift.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts import poc_health_snmp as h  # noqa: E402


# ── derive_status ──────────────────────────────────────────────────────────
@pytest.mark.parametrize(
    "metrics, expect",
    [
        ({"cpu_used_pct": 10, "mem_used_pct": 20, "disk_used_pct": 30}, "OK"),
        ({"cpu_used_pct": 10, "mem_used_pct": 80}, "WARN"),          # mem crosses 75
        ({"cpu_used_pct": 95}, "CRIT"),                              # cpu crosses 90
        ({"disk_used_pct": 92}, "CRIT"),                            # worst-of wins
        ({}, "OK"),                                                 # nothing known
    ],
)
def test_derive_status(metrics: dict, expect: str) -> None:
    assert h.derive_status(metrics, warn=75.0, crit=90.0) == expect


# ── _to_float (net-snmp value quirks) ──────────────────────────────────────
@pytest.mark.parametrize(
    "raw, expect",
    [
        ("87", 87.0),
        ('"0.42"', 0.42),                 # quoted STRING (laLoad)
        ("12345 KB", 12345.0),            # trailing units
        ("No Such Object available", None),
        ("No Such Instance currently exists", None),
        ("", None),
    ],
)
def test_to_float(raw: str, expect) -> None:
    assert h._to_float(raw) == expect


# ── parse_snmp_health: captured net-snmp values -> normalized metrics ──────
def _raw_from(values_by_key: dict) -> dict:
    """Map logical keys -> the OID strings the collector actually queries."""
    return {h.OIDS[k]: v for k, v in values_by_key.items()}


def test_parse_snmp_health_full() -> None:
    raw = _raw_from(
        {
            "cpu_idle": "87",
            "mem_total": "32000000",   # KB -> ~31250 MB
            "mem_avail": "18000000",
            "swap_total": "8388608",   # 8 GB in KB
            "swap_avail": "8200000",
            "disk_pct": "38",
            "disk_total": "209715200",  # KB -> 200 GB
            "disk_used": "79691776",
            "load1": '"0.42"',
            "load5": '"0.39"',
            "load15": '"0.35"',
            "uptime": "86400000",       # timeticks (1/100s) -> 864000 s
        }
    )
    m = h.parse_snmp_health(raw)
    assert m["cpu_idle_pct"] == 87.0
    assert m["cpu_used_pct"] == 13.0
    assert m["mem_used_pct"] == pytest.approx(43.75, abs=0.1)
    assert m["disk_used_pct"] == 38.0
    assert m["disk_total_gb"] == pytest.approx(200.0, abs=0.5)
    assert m["load1"] == 0.42 and m["load15"] == 0.35
    assert m["uptime_s"] == 864000.0


def test_parse_snmp_health_partial_no_swap_no_disk() -> None:
    """Missing OIDs must drop cleanly, not raise or zero-divide."""
    raw = _raw_from({"cpu_idle": "50", "mem_total": "1000000", "mem_avail": "250000",
                     "swap_total": "0"})
    m = h.parse_snmp_health(raw)
    assert m["cpu_used_pct"] == 50.0
    assert m["mem_used_pct"] == 75.0
    assert m["swap_used_pct"] == 0.0          # zero swap -> 0%, not a crash
    assert "disk_used_pct" not in m           # no disk OID answered


# ── format_line: the Splunk key=value contract ─────────────────────────────
def test_format_line_shape() -> None:
    metrics = {
        "cpu_used_pct": 12.5, "cpu_idle_pct": 87.5,
        "mem_used_pct": 43.1, "mem_total_mb": 32000.0, "mem_used_mb": 13792.0,
        "disk_used_pct": 38.0, "load1": 0.42, "uptime_s": 864000.0,
    }
    line = h.format_line(metrics, member="infoblox-poc-01", ts="2026-06-23T02:15:03Z")
    assert line.startswith("2026-06-23T02:15:03Z member=infoblox-poc-01 ")
    assert "cpu_used_pct=12.5" in line
    assert "mem_total_mb=32000 " in line       # *_mb formatted as integer
    assert "load1=0.42" in line                # load keeps 2dp
    assert "uptime_s=864000" in line
    assert line.endswith("health_status=OK")   # status always last
    # every token after the timestamp is a key=value pair
    for tok in line.split(" ")[1:]:
        assert "=" in tok


def test_format_line_status_crit() -> None:
    line = h.format_line({"cpu_used_pct": 99.0}, member="m", ts="T")
    assert line.endswith("health_status=CRIT")


# ── local (/proc) collection on the test host ──────────────────────────────
def test_read_local_health_real() -> None:
    m = h.read_local_health(sample_s=0.1)
    for k in ("cpu_used_pct", "cpu_idle_pct", "mem_used_pct", "disk_used_pct"):
        assert k in m, f"missing {k}"
    assert 0.0 <= m["cpu_used_pct"] <= 100.0
    assert 0.0 <= m["mem_used_pct"] <= 100.0
    assert abs((m["cpu_used_pct"] + m["cpu_idle_pct"]) - 100.0) < 0.2


# ── end-to-end --self via main() ───────────────────────────────────────────
def test_main_self_stdout(capsys: pytest.CaptureFixture[str]) -> None:
    rc = h.main(["--self", "--member", "unit-test"])
    assert rc == 0
    out = capsys.readouterr().out.strip()
    assert out.startswith("")  # produced a line
    assert "member=unit-test" in out
    assert "health_status=" in out
    assert "cpu_used_pct=" in out


def test_main_requires_a_source() -> None:
    rc = h.main([])  # neither --self nor --target
    assert rc == 2


# ── SNMP subprocess path (simulated net-snmp, no live agent) ───────────────
def test_snmp_get_maps_values_in_order(monkeypatch: pytest.MonkeyPatch) -> None:
    """snmp_get uses -Oqv (value-only, in OID order); confirm cmd + mapping."""
    import subprocess

    captured = {}

    class _Proc:
        returncode = 0
        # one value per OID, same order as requested
        stdout = "\n".join(["87", "32000000", "18000000"]) + "\n"
        stderr = ""

    def fake_run(cmd, **kw):  # noqa: ANN001, ANN003
        captured["cmd"] = cmd
        return _Proc()

    monkeypatch.setattr(h.shutil, "which", lambda _name: "/usr/bin/snmpget")
    monkeypatch.setattr(subprocess, "run", fake_run)

    oids = [h.OIDS["cpu_idle"], h.OIDS["mem_total"], h.OIDS["mem_avail"]]
    out = h.snmp_get("10.0.0.1", "public", "2c", oids)

    assert out[h.OIDS["cpu_idle"]] == "87"
    assert out[h.OIDS["mem_total"]] == "32000000"
    # built a numeric, value-only snmpget v2c command
    assert "-v" in captured["cmd"] and "2c" in captured["cmd"]
    assert "-Oqv" in captured["cmd"] and "10.0.0.1" in captured["cmd"]
    # and the parsed metrics come out right
    m = h.parse_snmp_health(out)
    assert m["cpu_used_pct"] == 13.0
    assert m["mem_used_pct"] == pytest.approx(43.75, abs=0.1)


def test_snmp_get_missing_binary(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(h.shutil, "which", lambda _name: None)
    with pytest.raises(RuntimeError, match="net-snmp"):
        h.snmp_get("10.0.0.1", "public", "2c", [".1.2.3"])
