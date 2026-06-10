#!/usr/bin/env python3
"""Render templates/vector.toml.tmpl into a concrete vector.toml using config.toml.

Writes to stdout by default; use --output to write to a file.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Add the repo root so `scripts.lib` is importable when run as a script.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402
from scripts.lib.render import render  # noqa: E402

JSONL_BLOCK = '''
[sinks.jsonl_archive]
type = "file"
inputs = ["dnstap_enriched"]
path = "{jsonl_path}"
encoding.codec = "json"
'''

SPLUNK_BLOCK = '''
[sinks.splunk_hec]
type = "splunk_hec_logs"
# NIOS-style syslog lines (see transforms.dnstap_nios_syslog) so Splunk sees
# the same format InfoBlox DNS query/response logging produces; pair with
# sourcetype infoblox:dns for the Splunk Add-on for Infoblox.
inputs = ["dnstap_nios_syslog"]
endpoint = "{hec_url}"
default_token = "{hec_token}"
index = "{index}"
sourcetype = "{sourcetype}"
source = "{source}"
tls.verify_certificate = {verify_tls}
encoding.codec = "text"
'''


def _splunk_endpoint(hec_url: str) -> str:
    """Vector's splunk_hec_logs wants the BASE URL and appends the collector
    path itself; accept either form in config.toml and strip the path here."""
    url = hec_url.rstrip("/")
    for suffix in ("/services/collector/event", "/services/collector"):
        if url.endswith(suffix):
            url = url[: -len(suffix)]
            break
    return url


def _splunk_block(c: cfgmod.SplunkConfig) -> str:
    if not c.enabled:
        return "# Splunk HEC sink disabled in config.toml ([splunk].enabled = false)."
    if not c.hec_url or not c.hec_token:
        return (
            "# Splunk HEC sink enabled but missing hec_url or hec_token "
            "(set SPLUNK_HEC_TOKEN env var)."
        )
    return SPLUNK_BLOCK.format(
        hec_url=_splunk_endpoint(c.hec_url),
        hec_token=c.hec_token,
        index=c.index,
        sourcetype=c.sourcetype,
        source=c.source,
        verify_tls=str(c.verify_tls).lower(),
    )


def _jsonl_block(path: str) -> str:
    if not path:
        return "# JSONL archive disabled (vector.jsonl_path is empty)."
    return JSONL_BLOCK.format(jsonl_path=path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml", help="path to config.toml")
    parser.add_argument(
        "--template",
        default=None,
        help="path to vector.toml.tmpl (default: templates/vector.toml.tmpl)",
    )
    parser.add_argument(
        "--output",
        default="-",
        help="output path, or '-' for stdout (default)",
    )
    args = parser.parse_args(argv)

    cfg = cfgmod.load(args.config)
    repo_root = cfgmod.find_repo_root()
    template_path = Path(args.template or (repo_root / "templates" / "vector.toml.tmpl"))

    rendered = render(
        template_path,
        {
            "data_dir": cfg.vector.data_dir,
            "listen_host": cfg.receiver.listen_host,
            "listen_port": str(cfg.receiver.listen_port),
            "metrics_listen": cfg.vector.metrics_listen,
            "jsonl_sink_block": _jsonl_block(cfg.vector.jsonl_path),
            "splunk_sink_block": _splunk_block(cfg.splunk),
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
