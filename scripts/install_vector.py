#!/usr/bin/env python3
"""Download and install Vector as a native binary (no Docker).

What this does:
  1. Detects OS/arch + glibc; picks the musl Vector build on old glibc
     (RHEL 7) and the gnu build elsewhere.
  2. Downloads the matching Vector release tarball into ./vendor/.
  3. Verifies the SHA256 against the published .sha256 file when available.
  4. Extracts the binary to <install_prefix>/bin/vector.
  5. Optionally creates a `vector` system user.
  6. Optionally writes a systemd unit compatible with the host's systemd
     version (StateDirectory / AmbientCapabilities are omitted on RHEL 7).
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import os
import shutil
import ssl
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402
from scripts.lib.platform_info import HostInfo, detect, systemd_unit  # noqa: E402
from scripts.lib.sysuser import ensure_system_user  # noqa: E402

log = logging.getLogger("install_vector")

VECTOR_RELEASE_URL = (
    "https://github.com/vectordotdev/vector/releases/download/v{version}/"
    "vector-{version}-{arch_tag}.tar.gz"
)
VECTOR_SHA_URL = VECTOR_RELEASE_URL + ".sha256"


def _ssl_context() -> ssl.SSLContext | None:
    """Return an unverified SSL context when DNSTAP_INSECURE_DOWNLOADS is set.

    Escape hatch for hosts behind a TLS-intercepting proxy whose root CA is
    not in the trust store (corporate networks). Verification stays ON by
    default; this only disables it when explicitly opted in via env var.
    """
    if os.environ.get("DNSTAP_INSECURE_DOWNLOADS", "").lower() in ("1", "true", "yes", "on"):
        print("  ! DNSTAP_INSECURE_DOWNLOADS set — skipping TLS certificate verification")
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    return None


def _download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  downloading {url}")
    with urllib.request.urlopen(url, timeout=60, context=_ssl_context()) as resp, dest.open("wb") as fp:
        shutil.copyfileobj(resp, fp)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fp:
        for chunk in iter(lambda: fp.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _maybe_verify(tarball: Path, sha_url: str) -> None:
    try:
        with urllib.request.urlopen(sha_url, timeout=15, context=_ssl_context()) as resp:
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
    cfg: cfgmod.VectorConfig,
    host: HostInfo,
    write_systemd: bool,
    force: bool,
    vendor_dir: Path,
) -> Path:
    arch_tag = host.vector_arch_tag
    bin_dir = Path(cfg.install_prefix) / "bin"
    target_bin = bin_dir / "vector"

    if target_bin.exists() and not force:
        print(f"  {target_bin} already exists (use --force to reinstall)")
    else:
        url = VECTOR_RELEASE_URL.format(version=cfg.version, arch_tag=arch_tag)
        sha_url = VECTOR_SHA_URL.format(version=cfg.version, arch_tag=arch_tag)

        with tempfile.TemporaryDirectory(prefix="vector-dl-") as td:
            tarball = vendor_dir / f"vector-{cfg.version}-{arch_tag}.tar.gz"
            if not tarball.exists() or force:
                _download(url, tarball)
            _maybe_verify(tarball, sha_url)
            extracted = _extract_binary(tarball, Path(td))
            bin_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(extracted, target_bin)
            target_bin.chmod(0o755)
        print(f"  installed {target_bin} (build={arch_tag})")

    # Pre-create directories the renderer will write into.
    Path(cfg.data_dir).mkdir(parents=True, exist_ok=True)
    Path(cfg.config_path).parent.mkdir(parents=True, exist_ok=True)
    if cfg.jsonl_path:
        Path(cfg.jsonl_path).parent.mkdir(parents=True, exist_ok=True)

    if write_systemd:
        if not host.has_systemd:
            print("  ! systemd not detected — skipping unit file (run vector manually)")
            return target_bin
        user = ensure_system_user("vector")
        unit = systemd_unit(
            description="Vector — dnstap receiver and metrics exporter",
            exec_start=f"{target_bin} --config {cfg.config_path}",
            user=user,
            group=user,
            state_dir_name="vector",
            host=host,
        )
        unit_path = Path("/etc/systemd/system/vector.service")
        unit_path.write_text(unit)
        print(f"  wrote {unit_path} (systemd v{host.systemd_version}, user={user})")
        # Make data/log dirs writable by the chosen user.
        try:
            shutil.chown(cfg.data_dir, user=user, group=user)
            if cfg.jsonl_path:
                jsonl_dir = str(Path(cfg.jsonl_path).parent)
                shutil.chown(jsonl_dir, user=user, group=user)
        except (LookupError, PermissionError, OSError) as e:
            log.warning("could not chown %s: %s", cfg.data_dir, e)
        print("  next: sudo systemctl daemon-reload && sudo systemctl enable --now vector")

    return target_bin


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml")
    parser.add_argument("--force", action="store_true", help="redownload and overwrite")
    parser.add_argument(
        "--no-systemd",
        action="store_true",
        help="don't write a systemd unit (default: write one on systemd hosts)",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(levelname)-7s %(name)s :: %(message)s",
    )

    cfg = cfgmod.load(args.config)
    repo_root = cfgmod.find_repo_root()
    vendor = repo_root / "vendor"
    vendor.mkdir(exist_ok=True)

    host = detect()
    print(f"  host: {host.distro} {host.distro_major} ({host.os}/{host.arch}), "
          f"wsl={host.is_wsl}, systemd={host.systemd_version or 'n/a'}, "
          f"glibc={host.glibc_version or 'n/a'}")
    install(
        cfg=cfg.vector,
        host=host,
        write_systemd=not args.no_systemd,
        force=args.force,
        vendor_dir=vendor,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PermissionError as e:
        print(f"permission denied: {e}", file=sys.stderr)
        print(
            "hint: re-run with sudo, or set vector.install_prefix in config.toml "
            "to a user-owned directory.",
            file=sys.stderr,
        )
        sys.exit(1)
    except OSError as e:
        print(f"i/o error: {e}", file=sys.stderr)
        sys.exit(1)
