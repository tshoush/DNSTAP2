"""OS / arch / glibc / systemd detection for picking the right binary
tarballs and generating compatible systemd units.
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class HostInfo:
    os: str                # "linux" | "darwin"
    arch: str              # "x86_64" | "aarch64"
    distro: str            # "ubuntu" | "debian" | "rhel" | "centos" | "rocky" | "almalinux" | "fedora" | "macos" | "unknown"
    distro_major: int      # 7, 8, 9, ... ; 0 if unknown
    is_wsl: bool
    has_systemd: bool
    systemd_version: int   # 0 if no systemd
    glibc_version: tuple[int, int] | None  # (2, 17) for RHEL 7; None on macOS

    @property
    def uses_musl_vector(self) -> bool:
        """True if we should pick the musl-built Vector tarball instead of gnu.

        Vector's gnu build needs glibc 2.28+. RHEL 7 ships glibc 2.17 — fall
        back to the musl build, which is glibc-independent.
        """
        if self.os != "linux":
            return False
        if self.glibc_version is None:
            return False
        return self.glibc_version < (2, 28)

    @property
    def vector_arch_tag(self) -> str:
        if self.os == "linux":
            libc = "musl" if self.uses_musl_vector else "gnu"
            return f"{self.arch}-unknown-linux-{libc}"
        if self.os == "darwin":
            return f"{self.arch}-apple-darwin"
        raise RuntimeError(f"unsupported OS: {self.os}")

    @property
    def prometheus_arch_tag(self) -> str:
        # Prometheus is a static Go binary — no glibc concern.
        arch = "amd64" if self.arch == "x86_64" else "arm64"
        return f"{self.os}-{arch}"

    @property
    def systemd_supports_state_directory(self) -> bool:
        return self.systemd_version >= 235  # added in systemd 235

    @property
    def systemd_supports_ambient_caps(self) -> bool:
        return self.systemd_version >= 229  # added in systemd 229

    @property
    def systemd_supports_dynamic_user(self) -> bool:
        return self.systemd_version >= 235


# ─────────────────────────────────────────────────────────────────────────── helpers

def _detect_distro() -> tuple[str, int]:
    """Parse /etc/os-release into (distro_id, major_version)."""
    if not os.path.exists("/etc/os-release"):
        return "unknown", 0
    info: dict[str, str] = {}
    with open("/etc/os-release", encoding="utf-8") as fp:
        for line in fp:
            if "=" not in line:
                continue
            k, _, v = line.strip().partition("=")
            info[k] = v.strip().strip('"')
    distro = info.get("ID", "unknown").lower()
    version_id = info.get("VERSION_ID", "")
    major = 0
    if version_id:
        try:
            major = int(version_id.split(".")[0])
        except ValueError:
            major = 0
    return distro, major


def _detect_wsl() -> bool:
    """Detect WSL by sniffing the kernel release string."""
    for path in ("/proc/sys/kernel/osrelease", "/proc/version"):
        if os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as fp:
                    content = fp.read().lower()
            except OSError:
                continue
            if "microsoft" in content or "wsl" in content:
                return True
    return False


def _detect_systemd_version() -> tuple[bool, int]:
    """Return (has_systemd, version) where version is the integer release.

    Reports (False, 0) on macOS or when systemctl is absent.
    """
    if not shutil.which("systemctl"):
        return False, 0
    try:
        proc = subprocess.run(
            ["systemctl", "--version"],
            capture_output=True, text=True, timeout=3, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False, 0
    if proc.returncode != 0:
        return False, 0
    m = re.search(r"systemd\s+(\d+)", proc.stdout)
    if not m:
        return True, 0  # systemctl runs but we couldn't parse — assume present
    return True, int(m.group(1))


def _detect_glibc() -> tuple[int, int] | None:
    """Return (major, minor) glibc version, or None if not glibc / not Linux."""
    try:
        ver_tuple = platform.libc_ver()  # ("glibc", "2.17") on RHEL 7
    except Exception:  # noqa: BLE001
        return None
    name, ver = ver_tuple
    if not name or "glibc" not in name.lower():
        return None
    m = re.match(r"(\d+)\.(\d+)", ver or "")
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def detect() -> HostInfo:
    sysname = platform.system().lower()
    if sysname == "darwin":
        os_ = "darwin"
    elif sysname == "linux":
        os_ = "linux"
    else:
        raise RuntimeError(f"unsupported OS for install scripts: {sysname}")

    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        arch = "x86_64"
    elif machine in ("aarch64", "arm64"):
        arch = "aarch64"
    else:
        raise RuntimeError(f"unsupported arch: {machine}")

    distro = "macos" if os_ == "darwin" else "unknown"
    distro_major = 0
    if os_ == "linux":
        distro, distro_major = _detect_distro()

    is_wsl = _detect_wsl() if os_ == "linux" else False
    has_systemd, systemd_version = _detect_systemd_version() if os_ == "linux" else (False, 0)
    glibc = _detect_glibc() if os_ == "linux" else None

    return HostInfo(
        os=os_,
        arch=arch,
        distro=distro,
        distro_major=distro_major,
        is_wsl=is_wsl,
        has_systemd=has_systemd,
        systemd_version=systemd_version,
        glibc_version=glibc,
    )


# ─────────────────────────────────────────────────────── systemd unit composition

def systemd_unit(
    *,
    description: str,
    exec_start: str,
    user: str,
    group: str,
    state_dir_name: str | None,
    host: HostInfo,
) -> str:
    """Render a systemd unit compatible with the host's systemd version.

    On systemd 235+ we use StateDirectory / ProtectSystem=strict — the modern
    hardening surface. On systemd 219 (RHEL 7) we degrade to the directives
    that actually existed in that release.
    """
    lines = [
        "[Unit]",
        f"Description={description}",
        "After=network-online.target",
        "Wants=network-online.target",
        "",
        "[Service]",
        "Type=simple",
        f"ExecStart={exec_start}",
        "Restart=on-failure",
        "RestartSec=5",
        f"User={user}",
        f"Group={group}",
    ]

    # Hardening directives that exist on systemd 215+ (RHEL 7's 219 is OK).
    lines += [
        "NoNewPrivileges=true",
        "ProtectSystem=full",
        "ProtectHome=true",
    ]

    if host.systemd_supports_ambient_caps:
        lines.append("AmbientCapabilities=CAP_NET_BIND_SERVICE")

    if state_dir_name and host.systemd_supports_state_directory:
        lines.append(f"StateDirectory={state_dir_name}")

    lines += [
        "",
        "[Install]",
        "WantedBy=multi-user.target",
        "",
    ]
    return "\n".join(lines)
