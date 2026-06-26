"""Tests for the template renderer and config rendering scripts."""

from __future__ import annotations

import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

REPO_ROOT = Path(__file__).resolve().parents[1]


def _write_cfg(
    path: Path,
    splunk_enabled: bool = False,
    jsonl_path: str = "/tmp/dnstap.jsonl",
    splunk_syslog_enabled: bool = False,
) -> None:
    body = f"""
    [infoblox]
    host = "192.168.1.224"
    username = "admin"
    password = "lab"

    [receiver]
    listen_host = "0.0.0.0"
    listen_port = 6000

    [vector]
    metrics_listen = "0.0.0.0:9598"
    jsonl_path = "{jsonl_path}"
    data_dir = "/var/lib/vector"

    [prometheus]
    scrape_interval = "15s"

    [splunk]
    enabled = {str(splunk_enabled).lower()}
    hec_url = "https://splunk.example.com:8088/services/collector/event"
    hec_token = "abc"

    [splunk_syslog]
    enabled = {str(splunk_syslog_enabled).lower()}
    host = "10.0.0.9"
    port = 5514
    mode = "tcp"
    """
    path.write_text(textwrap.dedent(body), encoding="utf-8")


def _run(cmd: list[str]) -> str:
    proc = subprocess.run(
        cmd, cwd=REPO_ROOT, check=True, capture_output=True, text=True
    )
    return proc.stdout


def test_render_vector_config_includes_dnstap_source(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write_cfg(cfg_path)
    out = _run([sys.executable, "scripts/render_vector_config.py", "--config", str(cfg_path)])
    assert 'type = "dnstap"' in out
    assert 'address = "0.0.0.0:6000"' in out
    assert "[transforms.dnstap_enriched]" in out
    assert "[transforms.dnstap_nios_syslog]" in out
    assert "[transforms.dnstap_metrics]" in out
    assert "[sinks.prom_exporter]" in out
    assert 'address = "0.0.0.0:9598"' in out


def test_render_vector_config_jsonl_enabled(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write_cfg(cfg_path, jsonl_path="/var/log/dnstap/events.jsonl")
    out = _run([sys.executable, "scripts/render_vector_config.py", "--config", str(cfg_path)])
    assert "[sinks.jsonl_archive]" in out
    assert "/var/log/dnstap/events.jsonl" in out


def test_render_vector_config_jsonl_disabled(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write_cfg(cfg_path, jsonl_path="")
    out = _run([sys.executable, "scripts/render_vector_config.py", "--config", str(cfg_path)])
    assert "[sinks.jsonl_archive]" not in out
    assert "JSONL archive disabled" in out


def test_render_vector_config_splunk_disabled(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write_cfg(cfg_path, splunk_enabled=False)
    out = _run([sys.executable, "scripts/render_vector_config.py", "--config", str(cfg_path)])
    assert "[sinks.splunk_hec]" not in out


def test_render_vector_config_splunk_enabled(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write_cfg(cfg_path, splunk_enabled=True)
    out = _run([sys.executable, "scripts/render_vector_config.py", "--config", str(cfg_path)])
    assert "[sinks.splunk_hec]" in out
    assert "splunk.example.com" in out
    # Splunk receives NIOS-style syslog text lines, not JSON events.
    splunk_block = out[out.index("[sinks.splunk_hec]"):]
    assert 'inputs = ["dnstap_nios_syslog"]' in splunk_block
    assert 'encoding.codec = "text"' in splunk_block


def test_render_vector_config_splunk_syslog_disabled(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write_cfg(cfg_path, splunk_syslog_enabled=False)
    out = _run([sys.executable, "scripts/render_vector_config.py", "--config", str(cfg_path)])
    assert "[sinks.splunk_syslog]" not in out
    assert "Splunk raw-syslog sink disabled" in out


def test_render_vector_config_splunk_syslog_enabled(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write_cfg(cfg_path, splunk_syslog_enabled=True)
    out = _run([sys.executable, "scripts/render_vector_config.py", "--config", str(cfg_path)])
    assert "[sinks.splunk_syslog]" in out
    block = out[out.index("[sinks.splunk_syslog]"):]
    assert 'inputs = ["dnstap_nios_syslog"]' in block
    assert 'address = "10.0.0.9:5514"' in block
    assert 'mode = "tcp"' in block
    assert 'encoding.codec = "text"' in block


def test_render_prometheus_config_scrape_target(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write_cfg(cfg_path)
    out = _run([sys.executable, "scripts/render_prometheus_config.py", "--config", str(cfg_path)])
    assert "scrape_interval: 15s" in out
    assert "localhost:9598" in out  # 0.0.0.0 → localhost translation
    assert "job_name: vector_dnstap" in out


def test_help_does_not_error() -> None:
    # CLI smoke check — argparse should not blow up.
    subprocess.run(
        [sys.executable, "scripts/render_vector_config.py", "--help"],
        cwd=REPO_ROOT, check=True, capture_output=True,
    )
    subprocess.run(
        [sys.executable, "scripts/render_prometheus_config.py", "--help"],
        cwd=REPO_ROOT, check=True, capture_output=True,
    )
