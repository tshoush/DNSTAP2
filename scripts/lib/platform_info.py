"""OS / arch detection for picking the right binary tarballs."""

from __future__ import annotations

import platform
import shutil
from dataclasses import dataclass


@dataclass(frozen=True)
class HostInfo:
    os: str          # "linux" | "darwin"
    arch: str        # "x86_64" | "aarch64"
    has_systemd: bool

    @property
    def vector_arch_tag(self) -> str:
        # Vector release naming, see https://github.com/vectordotdev/vector/releases
        if self.os == "linux":
            return f"{self.arch}-unknown-linux-gnu"
        if self.os == "darwin":
            return f"{self.arch}-apple-darwin"
        raise RuntimeError(f"unsupported OS: {self.os}")

    @property
    def prometheus_arch_tag(self) -> str:
        # Prometheus release naming, see https://github.com/prometheus/prometheus/releases
        arch = "amd64" if self.arch == "x86_64" else "arm64"
        return f"{self.os}-{arch}"


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

    has_systemd = os_ == "linux" and shutil.which("systemctl") is not None
    return HostInfo(os=os_, arch=arch, has_systemd=has_systemd)
