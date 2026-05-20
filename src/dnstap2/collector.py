"""Collector — listens on UNIX or TCP, reads Frame Streams, dispatches to a sink."""

from __future__ import annotations

import logging
import os
import socket
from typing import Callable, Iterator

from dnstap2 import framestream
from dnstap2.decoder import decode_frame
from dnstap2.sinks.base import Sink

log = logging.getLogger(__name__)


def _accept_loop(server_sock: socket.socket) -> Iterator[socket.socket]:
    while True:
        conn, _addr = server_sock.accept()
        yield conn


def _make_unix_server(path: str) -> socket.socket:
    if os.path.exists(path):
        os.unlink(path)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    os.chmod(path, 0o660)
    s.listen(8)
    log.info("listening on unix:%s", path)
    return s


def _make_tcp_server(host: str, port: int) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    s.listen(8)
    log.info("listening on tcp:%s:%d", host, port)
    return s


def _serve_connection(conn: socket.socket, sink: Sink) -> None:
    """Read frames from one client connection and forward decoded events to the sink."""
    with conn, conn.makefile("rb", buffering=0) as stream:
        try:
            for payload in framestream.iter_frames(stream):
                event = decode_frame(payload)
                sink.write(event)
        except framestream.FrameStreamError as e:
            log.warning("frame error on connection: %s", e)
        except Exception:  # noqa: BLE001 — collector must keep running
            log.exception("unexpected error while processing connection")


def run(
    sink: Sink,
    *,
    unix_path: str | None = None,
    tcp: tuple[str, int] | None = None,
    on_ready: Callable[[], None] | None = None,
) -> None:
    """Run the collector loop. Blocks until interrupted.

    Exactly one of `unix_path` or `tcp` must be provided.
    """
    if (unix_path is None) == (tcp is None):
        raise ValueError("exactly one of unix_path / tcp must be set")

    server = _make_unix_server(unix_path) if unix_path else _make_tcp_server(*tcp)  # type: ignore[misc]
    if on_ready is not None:
        on_ready()

    try:
        with sink, server:
            for conn in _accept_loop(server):
                # Single-threaded for the lab tool. For real load, hand off
                # each `conn` to a thread or asyncio task here.
                _serve_connection(conn, sink)
    except KeyboardInterrupt:
        log.info("shutting down on keyboard interrupt")
    finally:
        if unix_path and os.path.exists(unix_path):
            try:
                os.unlink(unix_path)
            except OSError:
                pass
