"""dnstap2 CLI."""

from __future__ import annotations

import argparse
import logging
import os
import sys

from dnstap2 import __version__, collector
from dnstap2.sinks.base import Sink
from dnstap2.sinks.jsonl import JsonlSink
from dnstap2.sinks.splunk_hec import SplunkHecSink
from dnstap2.sinks.stdout import StdoutSink


def _build_sink(args: argparse.Namespace) -> Sink:
    if args.sink == "stdout":
        return StdoutSink()
    if args.sink == "jsonl":
        if not args.path:
            raise SystemExit("--path is required for --sink jsonl")
        return JsonlSink(args.path)
    if args.sink == "splunk":
        token = args.splunk_token or os.environ.get("SPLUNK_HEC_TOKEN")
        if not args.splunk_url:
            raise SystemExit("--splunk-url is required for --sink splunk")
        if not token:
            raise SystemExit("set --splunk-token or SPLUNK_HEC_TOKEN env var")
        return SplunkHecSink(
            url=args.splunk_url,
            token=token,
            index=args.splunk_index,
            sourcetype=args.splunk_sourcetype,
            source=args.splunk_source,
            verify_tls=not args.splunk_insecure,
        )
    raise SystemExit(f"unknown sink: {args.sink}")


def _parse_tcp(value: str) -> tuple[str, int]:
    host, _, port = value.rpartition(":")
    if not host or not port:
        raise argparse.ArgumentTypeError(f"expected host:port, got {value!r}")
    return host, int(port)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="dnstap2",
        description="Receive dnstap Frame Streams from a DNS server and forward events to a sink.",
    )
    p.add_argument("--version", action="version", version=f"dnstap2 {__version__}")

    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--unix", metavar="PATH", help="listen on a UNIX socket at PATH")
    src.add_argument(
        "--tcp",
        metavar="HOST:PORT",
        type=_parse_tcp,
        help="listen on TCP HOST:PORT (e.g. 0.0.0.0:6000)",
    )

    p.add_argument(
        "--sink",
        choices=["stdout", "jsonl", "splunk"],
        default="stdout",
        help="where to send decoded events (default: stdout)",
    )
    p.add_argument("--path", help="for --sink jsonl: file path to append to")

    p.add_argument("--splunk-url", help="Splunk HEC URL (.../services/collector/event)")
    p.add_argument("--splunk-token", help="Splunk HEC token (or set SPLUNK_HEC_TOKEN)")
    p.add_argument("--splunk-index", default="dns_dnstap")
    p.add_argument("--splunk-sourcetype", default="dnstap:json")
    p.add_argument("--splunk-source", default="dnstap2")
    p.add_argument(
        "--splunk-insecure",
        action="store_true",
        help="skip TLS verification (lab only)",
    )

    p.add_argument(
        "-v", "--verbose", action="count", default=0, help="-v info, -vv debug"
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    level = logging.WARNING - (10 * args.verbose)
    logging.basicConfig(
        level=max(level, logging.DEBUG),
        format="%(asctime)s %(levelname)-7s %(name)s :: %(message)s",
    )

    sink = _build_sink(args)
    collector.run(sink, unix_path=args.unix, tcp=args.tcp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
