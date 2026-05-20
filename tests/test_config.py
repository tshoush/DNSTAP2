"""Tests for scripts/lib/config.py."""

from __future__ import annotations

import os
import sys
import textwrap
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402


def _write(path: Path, body: str) -> None:
    path.write_text(textwrap.dedent(body), encoding="utf-8")


def test_loads_with_env_password(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    cfg_path = tmp_path / "config.toml"
    _write(
        cfg_path,
        """
        [infoblox]
        host = "192.168.1.224"
        username = "admin"
        wapi_version = "v2.13.7"
        verify_tls = false
        """,
    )
    monkeypatch.setenv("INFOBLOX_PASSWORD", "from-env")
    cfg = cfgmod.load(cfg_path)
    assert cfg.infoblox.host == "192.168.1.224"
    assert cfg.infoblox.password == "from-env"
    assert cfg.infoblox.verify_tls is False


def test_inline_password_wins_over_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg_path = tmp_path / "config.toml"
    _write(
        cfg_path,
        """
        [infoblox]
        host = "h"
        username = "u"
        password = "inline"
        """,
    )
    monkeypatch.setenv("INFOBLOX_PASSWORD", "from-env")
    cfg = cfgmod.load(cfg_path)
    assert cfg.infoblox.password == "inline"


def test_missing_host_raises(tmp_path: Path) -> None:
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, "[infoblox]\nusername = \"admin\"\n")
    with pytest.raises(ValueError):
        cfgmod.load(cfg_path)


def test_splunk_token_env_fallback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg_path = tmp_path / "config.toml"
    _write(
        cfg_path,
        """
        [infoblox]
        host = "h"
        username = "u"

        [splunk]
        enabled = true
        hec_url = "https://splunk.example.com:8088/services/collector/event"
        """,
    )
    monkeypatch.setenv("INFOBLOX_PASSWORD", "x")
    monkeypatch.setenv("SPLUNK_HEC_TOKEN", "hec-token-123")
    cfg = cfgmod.load(cfg_path)
    assert cfg.splunk.enabled is True
    assert cfg.splunk.hec_token == "hec-token-123"


def test_find_repo_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # Repo root has config.example.toml; pretend tmp_path is the repo root.
    (tmp_path / "config.example.toml").touch()
    sub = tmp_path / "scripts" / "lib"
    sub.mkdir(parents=True)
    monkeypatch.chdir(sub)
    found = cfgmod.find_repo_root()
    assert found == tmp_path.resolve()
