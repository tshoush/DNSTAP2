#!/usr/bin/env python3
"""Render templates/prometheus.yml.tmpl into a concrete prometheus.yml."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402
from scripts.lib.render import render  # noqa: E402


def _vector_metrics_target(metrics_listen: str) -> str:
    """Translate Vector's bind addr (0.0.0.0:9598) into a scrape target.

    If Vector listens on 0.0.0.0, Prometheus scrapes localhost on the same port.
    """
    host, _, port = metrics_listen.rpartition(":")
    if not host or host == "0.0.0.0":
        host = "localhost"
    return f"{host}:{port}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml")
    parser.add_argument("--template", default=None)
    parser.add_argument("--output", default="-")
    args = parser.parse_args(argv)

    cfg = cfgmod.load(args.config)
    repo_root = cfgmod.find_repo_root()
    template_path = Path(args.template or (repo_root / "templates" / "prometheus.yml.tmpl"))

    rendered = render(
        template_path,
        {
            "scrape_interval": cfg.prometheus.scrape_interval,
            "vector_metrics_target": _vector_metrics_target(cfg.vector.metrics_listen),
        },
    )

    if args.output == "-":
        sys.stdout.write(rendered)
    else:
        Path(args.output).write_text(rendered, encoding="utf-8")
        print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
