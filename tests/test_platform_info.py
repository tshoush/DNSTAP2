"""Tests for platform detection and systemd-unit composition.

We don't actually probe the running OS in these tests; we exercise the
pure logic by constructing HostInfo by hand for every interesting case
(RHEL 7, RHEL 8, Ubuntu under WSL2, macOS).
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib.platform_info import HostInfo, systemd_unit  # noqa: E402


def _host(**kw: object) -> HostInfo:
    """Build a HostInfo with sane defaults; override per test."""
    defaults: dict[str, object] = dict(
        os="linux",
        arch="x86_64",
        distro="rhel",
        distro_major=8,
        is_wsl=False,
        has_systemd=True,
        systemd_version=239,
        glibc_version=(2, 28),
    )
    defaults.update(kw)
    return HostInfo(**defaults)  # type: ignore[arg-type]


# ─────────────────────────────────────────────────────── musl vs gnu Vector

def test_rhel7_uses_musl_vector() -> None:
    h = _host(distro="rhel", distro_major=7, systemd_version=219, glibc_version=(2, 17))
    assert h.uses_musl_vector is True
    assert h.vector_arch_tag == "x86_64-unknown-linux-musl"


def test_rhel8_uses_gnu_vector() -> None:
    h = _host(distro="rhel", distro_major=8, systemd_version=239, glibc_version=(2, 28))
    assert h.uses_musl_vector is False
    assert h.vector_arch_tag == "x86_64-unknown-linux-gnu"


def test_ubuntu_wsl_uses_gnu_vector() -> None:
    h = _host(distro="ubuntu", distro_major=22, is_wsl=True, glibc_version=(2, 35))
    assert h.uses_musl_vector is False
    assert h.vector_arch_tag == "x86_64-unknown-linux-gnu"


def test_macos_arch_tag() -> None:
    h = _host(os="darwin", arch="aarch64", has_systemd=False, systemd_version=0, glibc_version=None)
    assert h.uses_musl_vector is False
    assert h.vector_arch_tag == "aarch64-apple-darwin"
    assert h.prometheus_arch_tag == "darwin-arm64"


# ─────────────────────────────────────────────────────── systemd unit composition

def test_unit_on_rhel7_systemd_219_omits_modern_directives() -> None:
    h = _host(distro="rhel", distro_major=7, systemd_version=219, glibc_version=(2, 17))
    unit = systemd_unit(
        description="Vector",
        exec_start="/usr/local/bin/vector --config /etc/vector/vector.toml",
        user="vector", group="vector",
        state_dir_name="vector",
        host=h,
    )
    # These directives need newer systemd than RHEL 7 has — must be absent.
    assert "StateDirectory=" not in unit
    assert "AmbientCapabilities=" not in unit
    # These were available in 215 — must be present.
    assert "NoNewPrivileges=true" in unit
    assert "ProtectSystem=full" in unit


def test_unit_on_rhel8_systemd_239_includes_modern_directives() -> None:
    h = _host(distro="rhel", distro_major=8, systemd_version=239)
    unit = systemd_unit(
        description="Vector",
        exec_start="/usr/local/bin/vector --config /etc/vector/vector.toml",
        user="vector", group="vector",
        state_dir_name="vector",
        host=h,
    )
    assert "StateDirectory=vector" in unit
    assert "AmbientCapabilities=CAP_NET_BIND_SERVICE" in unit


def test_unit_uses_root_when_user_resolves_to_root() -> None:
    h = _host(distro="ubuntu", distro_major=22, systemd_version=249)
    unit = systemd_unit(
        description="Prometheus",
        exec_start="/usr/local/bin/prometheus --foo",
        user="root", group="root",
        state_dir_name="prometheus",
        host=h,
    )
    assert "User=root" in unit
    assert "Group=root" in unit


def test_unit_omits_state_dir_when_not_requested() -> None:
    h = _host(systemd_version=249)
    unit = systemd_unit(
        description="X",
        exec_start="/x",
        user="x", group="x",
        state_dir_name=None,
        host=h,
    )
    assert "StateDirectory=" not in unit
