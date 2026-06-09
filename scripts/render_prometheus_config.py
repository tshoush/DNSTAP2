#!/usr/bin/env python3
"""Render templates/prometheus.yml.tmpl into a concrete prometheus.yml."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402
from scripts.lib.render import render  # noqa: E402

# Top-level prometheus.yml sections this renderer owns. Anything else found in
# an existing file (rule_files/alerting from install_alertmanager.sh,
# remote_write, ...) is preserved verbatim and re-appended.
OWNED_TOP_LEVEL = {"global", "scrape_configs"}


def _preserved_sections(existing: str) -> str:
    kept: list[str] = []
    keep = False
    for line in existing.splitlines():
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", line)
        if match:
            keep = match.group(1) not in OWNED_TOP_LEVEL
        if keep:
            kept.append(line)
    return "\n".join(kept).strip("\n")


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
    parser.add_argument(
        "--existing",
        default=None,
        help="existing prometheus.yml to preserve unowned sections from "
        "(defaults to --output when writing to a file; pass explicitly when piping to sudo tee)",
    )
    args = parser.parse_args(argv)

    cfg = cfgmod.load(args.config)
    repo_root = cfgmod.find_repo_root()
    template_path = Path(args.template or (repo_root / "templates" / "prometheus.yml.tmpl"))

    rendered = render(
        template_path,
        {
            "scrape_interval": cfg.prometheus.scrape_interval,
            "vector_metrics_target": _vector_metrics_target(cfg.vector.metrics_listen),
            # Optional alternative receiver; matches install_dnscollector_receiver.sh
            # PROM_PORT default (9599). Override via DNSCOLLECTOR_METRICS_TARGET.
            "dnscollector_metrics_target": os.environ.get(
                "DNSCOLLECTOR_METRICS_TARGET", "localhost:9599"
            ),
        },
    )

    existing_path = args.existing or (args.output if args.output != "-" else None)
    if existing_path and Path(existing_path).exists():
        preserved = _preserved_sections(Path(existing_path).read_text(encoding="utf-8"))
        if preserved:
            rendered = rendered.rstrip("\n") + "\n\n" + preserved + "\n"
            print(f"preserved existing sections from {existing_path}", file=sys.stderr)

    if args.output == "-":
        sys.stdout.write(rendered)
    else:
        Path(args.output).write_text(rendered, encoding="utf-8")
        print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
