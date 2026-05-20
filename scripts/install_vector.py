#!/usr/bin/env python3
"""Download and install Vector as a native binary (no Docker).

What this does:
  1. Detects OS/arch.
  2. Downloads the matching Vector release tarball from GitHub into ./vendor/.
  3. Verifies the SHA256 if a checksum is published alongside.
  4. Extracts the binary to <install_prefix>/bin/vector (default /usr/local/bin).
  5. Optionally writes a systemd unit at /etc/systemd/system/vector.service.

What this does NOT do:
  - Run vector. The setup orchestrator does that after configs are rendered.
  - Manage upgrades. Re-run this script with --force to overwrite.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402
from scripts.lib.platform_info import detect  # noqa: E402

VECTOR_RELEASE_URL = (
    "https://packages.timber.io/vector/{version}/"
    "vector-{version}-{arch_tag}.tar.gz"
)
VECTOR_SHA_URL = VECTOR_RELEASE_URL + ".sha256"

SYSTEMD_UNIT = """\
[Unit]
Description=Vector — dnstap receiver and metrics exporter
Documentation=https://vector.dev
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={binary} --config {config}
Restart=on-failure
RestartSec=5
User=vector
Group=vector
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
StateDirectory=vector

[Install]
WantedBy=multi-user.target
"""


def _download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  downloading {url}")
    with urllib.request.urlopen(url, timeout=60) as resp, dest.open("wb") as fp:
        shutil.copyfileobj(resp, fp)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fp:
        for chunk in iter(lambda: fp.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _maybe_verify(tarball: Path, sha_url: str) -> None:
    try:
        with urllib.request.urlopen(sha_url, timeout=15) as resp:
            published = resp.read().decode().split()[0].strip()
    except Exception as e:  # noqa: BLE001
        print(f"  ! skipping SHA verification ({e})")
        return
    got = _sha256(tarball)
    if got != published:
        raise SystemExit(f"SHA256 mismatch: got {got}, expected {published}")
    print("  SHA256 verified")


def _extract_binary(tarball: Path, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tarball, "r:gz") as tar:
        for member in tar.getmembers():
            if member.name.endswith("/bin/vector"):
                src = tar.extractfile(member)
                if src is None:
                    continue
                dest = out_dir / "vector"
                with dest.open("wb") as out:
                    shutil.copyfileobj(src, out)
                dest.chmod(0o755)
                return dest
    raise SystemExit("vector binary not found inside tarball")


def install(
    *,
    version: str,
    install_prefix: str,
    config_path: str,
    write_systemd: bool,
    force: bool,
    vendor_dir: Path,
) -> Path:
    host = detect()
    arch_tag = host.vector_arch_tag
    bin_dir = Path(install_prefix) / "bin"
    target_bin = bin_dir / "vector"

    if target_bin.exists() and not force:
        print(f"  {target_bin} already exists (use --force to reinstall)")
    else:
        url = VECTOR_RELEASE_URL.format(version=version, arch_tag=arch_tag)
        sha_url = VECTOR_SHA_URL.format(version=version, arch_tag=arch_tag)

        with tempfile.TemporaryDirectory(prefix="vector-dl-") as td:
            tarball = vendor_dir / f"vector-{version}-{arch_tag}.tar.gz"
            if not tarball.exists() or force:
                _download(url, tarball)
            _maybe_verify(tarball, sha_url)
            extracted = _extract_binary(tarball, Path(td))
            bin_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(extracted, target_bin)
            target_bin.chmod(0o755)
        print(f"  installed {target_bin}")

    if write_systemd:
        if not host.has_systemd:
            print("  ! systemd not detected on this host — skipping unit file")
        else:
            unit_path = Path("/etc/systemd/system/vector.service")
            unit_path.write_text(
                SYSTEMD_UNIT.format(binary=str(target_bin), config=config_path)
            )
            print(f"  wrote {unit_path}")
            print("  next: sudo systemctl daemon-reload && sudo systemctl enable --now vector")

    return target_bin


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml")
    parser.add_argument("--force", action="store_true", help="redownload and overwrite")
    parser.add_argument(
        "--no-systemd",
        action="store_true",
        help="don't write a systemd unit (default: write one on Linux)",
    )
    args = parser.parse_args(argv)

    cfg = cfgmod.load(args.config)
    repo_root = cfgmod.find_repo_root()
    vendor = repo_root / "vendor"
    vendor.mkdir(exist_ok=True)

    install(
        version=cfg.vector.version,
        install_prefix=cfg.vector.install_prefix,
        config_path=cfg.vector.config_path,
        write_systemd=not args.no_systemd,
        force=args.force,
        vendor_dir=vendor,
    )

    # Pre-create directories the renderer will write into.
    Path(cfg.vector.data_dir).parent.mkdir(parents=True, exist_ok=True)
    Path(cfg.vector.config_path).parent.mkdir(parents=True, exist_ok=True)
    if cfg.vector.jsonl_path:
        Path(cfg.vector.jsonl_path).parent.mkdir(parents=True, exist_ok=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PermissionError as e:
        print(f"permission denied: {e}", file=sys.stderr)
        print("hint: re-run with sudo, or set vector.install_prefix to a user-owned dir.", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"i/o error: {e}", file=sys.stderr)
        sys.exit(1)
