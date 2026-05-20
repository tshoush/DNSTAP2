#!/usr/bin/env python3
"""Download and install Prometheus as a native binary (no Docker)."""

from __future__ import annotations

import argparse
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402
from scripts.lib.platform_info import detect  # noqa: E402

PROM_URL = (
    "https://github.com/prometheus/prometheus/releases/download/"
    "v{version}/prometheus-{version}.{arch_tag}.tar.gz"
)

SYSTEMD_UNIT = """\
[Unit]
Description=Prometheus — scrapes Vector dnstap metrics
Documentation=https://prometheus.io
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart={binary} \\
  --config.file={config} \\
  --storage.tsdb.path={data_dir} \\
  --web.listen-address={listen}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
StateDirectory=prometheus

[Install]
WantedBy=multi-user.target
"""


def _download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  downloading {url}")
    with urllib.request.urlopen(url, timeout=60) as resp, dest.open("wb") as fp:
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
    version: str,
    install_prefix: str,
    config_path: str,
    data_dir: str,
    listen: str,
    write_systemd: bool,
    force: bool,
    vendor_dir: Path,
) -> Path:
    host = detect()
    arch_tag = host.prometheus_arch_tag
    bin_dir = Path(install_prefix) / "bin"
    target_bin = bin_dir / "prometheus"

    if target_bin.exists() and not force:
        print(f"  {target_bin} already exists (use --force to reinstall)")
    else:
        url = PROM_URL.format(version=version, arch_tag=arch_tag)
        with tempfile.TemporaryDirectory(prefix="prom-dl-") as td:
            tarball = vendor_dir / f"prometheus-{version}-{arch_tag}.tar.gz"
            if not tarball.exists() or force:
                _download(url, tarball)
            prom_src, promtool_src = _extract_binaries(tarball, Path(td))
            bin_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(prom_src, target_bin)
            shutil.copy2(promtool_src, bin_dir / "promtool")
            target_bin.chmod(0o755)
            (bin_dir / "promtool").chmod(0o755)
        print(f"  installed {target_bin} and {bin_dir / 'promtool'}")

    if write_systemd:
        if not host.has_systemd:
            print("  ! systemd not detected on this host — skipping unit file")
        else:
            unit_path = Path("/etc/systemd/system/prometheus.service")
            unit_path.write_text(
                SYSTEMD_UNIT.format(
                    binary=str(target_bin),
                    config=config_path,
                    data_dir=data_dir,
                    listen=listen,
                )
            )
            print(f"  wrote {unit_path}")
            print("  next: sudo systemctl daemon-reload && sudo systemctl enable --now prometheus")

    Path(data_dir).mkdir(parents=True, exist_ok=True)
    Path(config_path).parent.mkdir(parents=True, exist_ok=True)
    return target_bin


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--no-systemd", action="store_true")
    args = parser.parse_args(argv)

    cfg = cfgmod.load(args.config)
    repo_root = cfgmod.find_repo_root()
    vendor = repo_root / "vendor"
    vendor.mkdir(exist_ok=True)

    install(
        version=cfg.prometheus.version,
        install_prefix=cfg.prometheus.install_prefix,
        config_path=cfg.prometheus.config_path,
        data_dir=cfg.prometheus.data_dir,
        listen=cfg.prometheus.listen,
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
