"""Tests for scripts/configure_local_settings.py."""

from __future__ import annotations

import os
import stat
import sys
import textwrap
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.configure_local_settings import main  # noqa: E402


def _write(path: Path, body: str) -> None:
    path.write_text(textwrap.dedent(body), encoding="utf-8")


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def test_updates_config_with_backup_and_private_permissions(tmp_path: Path) -> None:
    example = tmp_path / "config.example.toml"
    config = tmp_path / "config.toml"
    _write(
        example,
        """
        [infoblox]
        host = "old-grid"
        username = "admin"
        password = ""
        verify_tls = false
        timeout = 10

        [receiver]
        listen_host = "0.0.0.0"
        listen_port = 6000
        advertised_host = "192.168.1.50"
        advertised_port = 6000

        [splunk]
        enabled = false
        hec_url = ""
        """,
    )
    _write(
        config,
        """
        [infoblox]
        host = "existing-grid"
        username = "ops"

        [custom]
        keep_me = "yes"
        """,
    )

    rc = main(
        [
            "--config",
            str(config),
            "--example",
            str(example),
            "--set",
            "infoblox.host=192.168.1.224",
            "--set",
            "receiver.listen_port=6001",
            "--set",
            "splunk.enabled=true",
        ]
    )

    assert rc == 0
    loaded = tomllib.loads(config.read_text(encoding="utf-8"))
    assert loaded["infoblox"]["host"] == "192.168.1.224"
    assert loaded["infoblox"]["username"] == "ops"
    assert loaded["receiver"]["listen_port"] == 6001
    assert loaded["splunk"]["enabled"] is True
    assert loaded["custom"]["keep_me"] == "yes"
    assert _mode(config) == 0o600

    backups = list(tmp_path.glob("config.toml.bak.*"))
    assert len(backups) == 1
    assert _mode(backups[0]) == 0o600


def test_writes_quoted_private_env_file(tmp_path: Path) -> None:
    env_file = tmp_path / ".env.dnstap2"

    rc = main(
        [
            "--env-file",
            str(env_file),
            "--env",
            f"DNSTAP2_CONFIG={tmp_path / 'config.toml'}",
            "--secret",
            "INFOBLOX_PASSWORD=pa'ss word",
        ]
    )

    assert rc == 0
    body = env_file.read_text(encoding="utf-8")
    assert "export DNSTAP2_CONFIG=" in body
    assert """export INFOBLOX_PASSWORD='pa'"'"'ss word'""" in body
    assert _mode(env_file) == 0o600


def test_blank_secret_does_not_clear_existing_value(tmp_path: Path) -> None:
    env_file = tmp_path / ".env.dnstap2"
    _write(env_file, "export INFOBLOX_PASSWORD='existing'\n")
    os.chmod(env_file, 0o600)

    rc = main(["--env-file", str(env_file), "--secret", "INFOBLOX_PASSWORD="])

    assert rc == 0
    assert "existing" in env_file.read_text(encoding="utf-8")


def test_env_rewrite_preserves_comments_and_unmanaged_lines(tmp_path: Path) -> None:
    env_file = tmp_path / ".env.dnstap2"
    _write(
        env_file,
        """\
        # prod creds — hand-maintained
        export EXTRA_PATH="$HOME/bin"
        export A=1 B=2
        export DNSTAP2_CONFIG='old.toml'
        """,
    )
    os.chmod(env_file, 0o600)

    rc = main(["--env-file", str(env_file), "--env", "DNSTAP2_CONFIG=config.toml"])

    assert rc == 0
    body = env_file.read_text(encoding="utf-8")
    assert "# prod creds — hand-maintained" in body
    assert 'export EXTRA_PATH="$HOME/bin"' in body
    assert "export A=1 B=2" in body
    assert "export DNSTAP2_CONFIG='config.toml'" in body
    assert "old.toml" not in body


def test_noop_update_does_not_rewrite_or_backup(tmp_path: Path) -> None:
    env_file = tmp_path / ".env.dnstap2"
    _write(env_file, "export DNSTAP2_CONFIG='config.toml'\n")
    os.chmod(env_file, 0o600)
    before = env_file.stat().st_mtime_ns

    rc = main(["--env-file", str(env_file), "--env", "DNSTAP2_CONFIG=config.toml"])

    assert rc == 0
    assert env_file.stat().st_mtime_ns == before
    assert list(tmp_path.glob(".env.dnstap2.bak.*")) == []


def test_config_rewrite_keeps_nested_tables_floats_and_root_keys(tmp_path: Path) -> None:
    example = tmp_path / "config.example.toml"
    config = tmp_path / "config.toml"
    _write(
        example,
        """
        [infoblox]
        host = "grid"
        """,
    )
    _write(
        config,
        """
        title = "lab"

        [infoblox]
        host = "grid"
        timeout = 2.5

        [vector]
        sinks = ["a", "b"]

        [vector.extra]
        nested = true
        """,
    )

    rc = main(
        [
            "--config",
            str(config),
            "--example",
            str(example),
            "--set",
            "infoblox.host=10.0.0.1",
        ]
    )

    assert rc == 0
    loaded = tomllib.loads(config.read_text(encoding="utf-8"))
    assert loaded["title"] == "lab"
    assert loaded["infoblox"]["host"] == "10.0.0.1"
    assert loaded["infoblox"]["timeout"] == 2.5
    assert loaded["vector"]["sinks"] == ["a", "b"]
    assert loaded["vector"]["extra"]["nested"] is True


def test_set_unknown_key_infers_type(tmp_path: Path) -> None:
    example = tmp_path / "config.example.toml"
    config = tmp_path / "config.toml"
    _write(example, "[infoblox]\nhost = \"grid\"\n")

    rc = main(
        [
            "--config",
            str(config),
            "--example",
            str(example),
            "--set",
            "splunk.enabled=false",
            "--set",
            "receiver.listen_port=6001",
        ]
    )

    assert rc == 0
    loaded = tomllib.loads(config.read_text(encoding="utf-8"))
    assert loaded["splunk"]["enabled"] is False
    assert loaded["receiver"]["listen_port"] == 6001
