"""Create POSIX system users for the Vector and Prometheus services.

If the user already exists, do nothing. If we cannot create the user
(non-root, missing useradd), fall back to root for the service unit and
warn the caller. This keeps the installer working on minimal RHEL 7
boxes and on Debian/Ubuntu equally.
"""

from __future__ import annotations

import logging
import os
import pwd
import shutil
import subprocess

log = logging.getLogger(__name__)


def user_exists(name: str) -> bool:
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


def ensure_system_user(name: str, *, home: str = "/var/lib") -> str:
    """Ensure `name` exists as a POSIX system user. Returns the effective
    username to use in the service unit — `name` on success, "root" if we
    could not create it.

    Caller decides whether running as root is acceptable for their threat
    model; we just report the truth.
    """
    if user_exists(name):
        return name

    if os.geteuid() != 0:
        log.warning(
            "cannot create user %s without root; the systemd unit will run as root.",
            name,
        )
        return "root"

    useradd = shutil.which("useradd")
    if not useradd:
        log.warning("no useradd binary found; the systemd unit will run as root.")
        return "root"

    cmd = [
        useradd,
        "--system",
        "--no-create-home",
        "--home-dir", f"{home}/{name}",
        "--shell", "/sbin/nologin",
        name,
    ]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as e:
        log.warning("useradd %s failed (%s); the systemd unit will run as root.",
                    name, e.stderr.strip() or e)
        return "root"
    log.info("created system user %s", name)
    return name
