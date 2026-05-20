#!/usr/bin/env python3
"""End-to-end dnstap flow test.

Verifies the receiver is actually getting frames after InfoBlox is configured.

Strategy:
  1. Start a lightweight local listener on the same port Vector would use.
     (You stop Vector first, run this for ~30s, then restart Vector.)
  2. Fire a handful of synthetic DNS queries at the grid master.
  3. Count frames received; assert at least N.

This is a quick smoke check. For real load testing, use dnsperf and check
Prometheus counters instead.
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402

# We re-use the dnstap2 framing reader to count frames.
from dnstap2 import framestream  # noqa: E402


def _listener(host: str, port: int, deadline: float, counters: dict[str, int]) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(4)
    srv.settimeout(1.0)
    while time.time() < deadline:
        try:
            conn, _ = srv.accept()
        except TimeoutError:
            continue
        counters["connections"] += 1
        with conn, conn.makefile("rb", buffering=0) as stream:
            try:
                for _payload in framestream.iter_frames(stream):
                    counters["frames"] += 1
            except framestream.FrameStreamError as e:
                counters["errors"] += 1
                print(f"  ! framing error: {e}", file=sys.stderr)
    srv.close()


def _fire_queries(grid_master: str, qnames: list[str]) -> int:
    """Send N synthetic A queries to the grid master. Returns count sent.

    Builds the simplest possible DNS query packets ourselves to avoid pulling
    in dnspython. Uses UDP/53.
    """
    sent = 0
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)
    for i, name in enumerate(qnames):
        txid = (0xBEEF + i) & 0xFFFF
        header = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0)  # standard query, RD
        qname = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
        question = qname + struct.pack(">HH", 1, 1)  # qtype A, qclass IN
        try:
            sock.sendto(header + question, (grid_master, 53))
            sent += 1
        except OSError as e:
            print(f"  ! send error: {e}", file=sys.stderr)
        # Try to read the response so the resolver-side dnstap event fires.
        try:
            sock.recv(512)
        except OSError:
            pass
    sock.close()
    return sent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml")
    parser.add_argument(
        "--seconds",
        type=int,
        default=20,
        help="how long the local listener stays up (default 20)",
    )
    parser.add_argument(
        "--qnames",
        default="example.com,www.iana.org,one.one.one.one,whoami.akamai.net,canhazip.com",
        help="comma-separated list of qnames to query",
    )
    parser.add_argument(
        "--min-frames",
        type=int,
        default=2,
        help="minimum frame count to consider the test passing (default 2)",
    )
    args = parser.parse_args(argv)

    cfg = cfgmod.load(args.config)
    qnames = [q.strip() for q in args.qnames.split(",") if q.strip()]

    print(f"Local listener   : {cfg.receiver.listen_host}:{cfg.receiver.listen_port}")
    print(f"Grid master      : {cfg.infoblox.host}")
    print(f"Synthetic qnames : {qnames}")
    print("---")

    counters = {"connections": 0, "frames": 0, "errors": 0}
    deadline = time.time() + args.seconds
    t = threading.Thread(
        target=_listener,
        args=(cfg.receiver.listen_host, cfg.receiver.listen_port, deadline, counters),
        daemon=True,
    )
    t.start()
    time.sleep(0.5)  # let the listener bind

    sent = _fire_queries(cfg.infoblox.host, qnames)
    print(f"sent {sent} synthetic queries")
    print("waiting for frames ...")
    t.join()

    print("---")
    print(f"connections : {counters['connections']}")
    print(f"frames      : {counters['frames']}")
    print(f"errors      : {counters['errors']}")

    if counters["frames"] >= args.min_frames:
        print(f"PASS: received >= {args.min_frames} frames")
        return 0
    print(
        f"FAIL: expected >= {args.min_frames} frames, got {counters['frames']}",
        file=sys.stderr,
    )
    print(
        "hint: make sure Vector is stopped (so we can bind the port), that "
        "dnstap is enabled on the grid member, and that the receiver address "
        "in InfoBlox points at this host.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
