#!/usr/bin/env python3
"""Download and install Prometheus as a native binary (no Docker).

Prometheus is a static Go binary so there is no glibc concern — the same
build runs on RHEL 7 and modern distros. We still tune the systemd unit
to the host's systemd version (RHEL 7 ships systemd 219 which doesn't
support StateDirectory / AmbientCapabilities).
"""

from __future__ import annotations

import argparse
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

log = logging.getLogger("install_prometheus")

PROM_URL = (
    "https://github.com/prometheus/prometheus/releases/download/"
    "v{version}/prometheus-{version}.{arch_tag}.tar.gz"
)


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


def _extract_binaries(tarball: Path, out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    prom_bin: Path | None = None
    promtool_bin: Path | None = None
    with tarfile.open(tarball, "r:gz") as tar:
        for m in tar.getmembers():
            base = Path(m.name).name
            if base in ("prometheus", "promtool") and m.isfile():
                src = tar.extractfile(m)
                if src is None:
                    continue
                dest = out_dir / base
                with dest.open("wb") as out:
                    shutil.copyfileobj(src, out)
                dest.chmod(0o755)
                if base == "prometheus":
                    prom_bin = dest
                else:
                    promtool_bin = dest
    if not prom_bin or not promtool_bin:
        raise SystemExit("prometheus/promtool binaries not found inside tarball")
    return prom_bin, promtool_bin


def install(
    *,
    cfg: cfgmod.PrometheusConfig,
    host: HostInfo,
    write_systemd: bool,
    force: bool,
    vendor_dir: Path,
) -> Path:
    arch_tag = host.prometheus_arch_tag
    bin_dir = Path(cfg.install_prefix) / "bin"
    target_bin = bin_dir / "prometheus"

    if target_bin.exists() and not force:
        print(f"  {target_bin} already exists (use --force to reinstall)")
    else:
        url = PROM_URL.format(version=cfg.version, arch_tag=arch_tag)
        with tempfile.TemporaryDirectory(prefix="prom-dl-") as td:
            tarball = vendor_dir / f"prometheus-{cfg.version}-{arch_tag}.tar.gz"
            if not tarball.exists() or force:
                _download(url, tarball)
            prom_src, promtool_src = _extract_binaries(tarball, Path(td))
            bin_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(prom_src, target_bin)
            shutil.copy2(promtool_src, bin_dir / "promtool")
            target_bin.chmod(0o755)
            (bin_dir / "promtool").chmod(0o755)
        print(f"  installed {target_bin} and {bin_dir / 'promtool'} (build={arch_tag})")

    Path(cfg.data_dir).mkdir(parents=True, exist_ok=True)
    Path(cfg.config_path).parent.mkdir(parents=True, exist_ok=True)

    if write_systemd:
        if not host.has_systemd:
            print("  ! systemd not detected — skipping unit file (run prometheus manually)")
            return target_bin
        user = ensure_system_user("prometheus")
        exec_start = (
            f"{target_bin} "
            f"--config.file={cfg.config_path} "
            f"--storage.tsdb.path={cfg.data_dir} "
            f"--web.listen-address={cfg.listen}"
        )
        unit = systemd_unit(
            description="Prometheus — scrapes Vector dnstap metrics",
            exec_start=exec_start,
            user=user,
            group=user,
            state_dir_name="prometheus",
            host=host,
        )
        unit_path = Path("/etc/systemd/system/prometheus.service")
        unit_path.write_text(unit)
        print(f"  wrote {unit_path} (systemd v{host.systemd_version}, user={user})")
        try:
            shutil.chown(cfg.data_dir, user=user, group=user)
        except (LookupError, PermissionError, OSError) as e:
            log.warning("could not chown %s: %s", cfg.data_dir, e)
        print("  next: sudo systemctl daemon-reload && sudo systemctl enable --now prometheus")

    return target_bin


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--no-systemd", action="store_true")
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
    install(
        cfg=cfg.prometheus,
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
        sys.exit(1)
    except OSError as e:
        print(f"i/o error: {e}", file=sys.stderr)
        sys.exit(1)
