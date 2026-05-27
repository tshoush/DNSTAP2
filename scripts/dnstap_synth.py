#!/usr/bin/env python3
"""dnstap_synth.py — synthetic dnstap traffic generator (stdlib only).

Builds valid DNS wire-format query/response packets, wraps each in a dnstap
protobuf message, frames them with the Frame Streams (fstrm) *bidirectional*
handshake, and streams them over TCP to a dnstap receiver (DNS-collector on
:6001 or Vector on :6000). Lets you exercise the pipeline end-to-end — metrics,
Loki, JSONL, Grafana panels — without a real DNS server or InfoBlox.

Examples:
    python3 scripts/dnstap_synth.py                              # 25 pairs/s for 60s to :6001
    python3 scripts/dnstap_synth.py --target 127.0.0.1:6001 --rate 40 --duration 300
    python3 scripts/dnstap_synth.py --count 100 --rate 200       # quick validation burst
"""
from __future__ import annotations

import argparse
import random
import socket
import struct
import sys
import time

# ── Frame Streams (fstrm) control frame types ──────────────────────────────
CONTROL_ACCEPT = 0x01
CONTROL_START = 0x02
CONTROL_STOP = 0x03
CONTROL_READY = 0x04
CONTROL_FINISH = 0x05
FIELD_CONTENT_TYPE = 0x01
CONTENT_TYPE = b"protobuf:dnstap.Dnstap"

# ── dnstap protobuf enums ──────────────────────────────────────────────────
DNSTAP_TYPE_MESSAGE = 1
MSG_CLIENT_QUERY = 5
MSG_CLIENT_RESPONSE = 6
SOCKET_FAMILY_INET = 1
SOCKET_PROTOCOL_UDP = 1


# ── minimal protobuf encoder ───────────────────────────────────────────────
def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def _tag(field: int, wire: int) -> bytes:
    return _varint((field << 3) | wire)


def pb_varint(field: int, value: int) -> bytes:
    return _tag(field, 0) + _varint(value)


def pb_bytes(field: int, data: bytes) -> bytes:
    return _tag(field, 2) + _varint(len(data)) + data


def pb_fixed32(field: int, value: int) -> bytes:
    return _tag(field, 5) + struct.pack("<I", value & 0xFFFFFFFF)


# ── DNS wire format ────────────────────────────────────────────────────────
def dns_name(name: str) -> bytes:
    out = bytearray()
    for label in name.rstrip(".").split("."):
        if not label:
            continue
        lb = label.encode("ascii")
        out.append(len(lb))
        out.extend(lb)
    out.append(0)
    return bytes(out)


def dns_query(qid: int, qname: str, qtype: int) -> bytes:
    # flags 0x0100 = QR=0 (query), RD=1
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    return header + dns_name(qname) + struct.pack(">HH", qtype, 1)


def dns_response(qid: int, qname: str, qtype: int, rcode: int) -> bytes:
    # flags 0x8180 = QR=1 (response), RD=1, RA=1; low nibble carries rcode
    flags = 0x8180 | (rcode & 0x0F)
    header = struct.pack(">HHHHHH", qid, flags, 1, 0, 0, 0)
    return header + dns_name(qname) + struct.pack(">HH", qtype, 1)


# ── dnstap message + Dnstap wrapper ────────────────────────────────────────
def dnstap_payload(msg_type: int, dns_wire: bytes, client_ip: str, client_port: int) -> bytes:
    now = time.time()
    sec = int(now)
    nsec = int((now - sec) * 1e9)

    m = b""
    m += pb_varint(1, msg_type)                      # Message.type
    m += pb_varint(2, SOCKET_FAMILY_INET)            # socket_family
    m += pb_varint(3, SOCKET_PROTOCOL_UDP)           # socket_protocol
    m += pb_bytes(4, socket.inet_aton(client_ip))    # query_address
    m += pb_varint(6, client_port)                   # query_port
    if msg_type == MSG_CLIENT_QUERY:
        m += pb_varint(8, sec)                       # query_time_sec
        m += pb_fixed32(9, nsec)                      # query_time_nsec
        m += pb_bytes(10, dns_wire)                  # query_message
    else:
        m += pb_varint(12, sec)                      # response_time_sec
        m += pb_fixed32(13, nsec)                     # response_time_nsec
        m += pb_bytes(14, dns_wire)                  # response_message

    d = b""
    d += pb_bytes(1, b"synthetic")                   # identity
    d += pb_bytes(2, b"dnstap_synth")                # version
    d += pb_bytes(14, m)                             # message
    d += pb_varint(15, DNSTAP_TYPE_MESSAGE)          # type = MESSAGE
    return d


# ── fstrm framing + handshake ──────────────────────────────────────────────
def data_frame(payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + payload


def control_frame(ctype: int, content_type: bytes | None = None) -> bytes:
    p = struct.pack(">I", ctype)
    if content_type is not None:
        p += struct.pack(">I", FIELD_CONTENT_TYPE)
        p += struct.pack(">I", len(content_type)) + content_type
    return struct.pack(">I", 0) + struct.pack(">I", len(p)) + p


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed during handshake")
        buf.extend(chunk)
    return bytes(buf)


def read_control(sock: socket.socket) -> int:
    esc = recv_exact(sock, 4)
    if esc != b"\x00\x00\x00\x00":
        raise ValueError("expected control-frame escape, got a data frame")
    (clen,) = struct.unpack(">I", recv_exact(sock, 4))
    payload = recv_exact(sock, clen)
    (ctype,) = struct.unpack(">I", payload[:4])
    return ctype


DOMAINS = [
    "example.com", "marriott.com", "cdn.fastly.net", "api.internal.lab",
    "mail.google.com", "wpad.corp", "nonexistent-zone.test",
    "s3.amazonaws.com", "login.microsoftonline.com", "time.cloudflare.com",
]
QTYPES = {"A": 1, "AAAA": 28, "MX": 15, "TXT": 16, "CNAME": 5, "PTR": 12, "NS": 2}
# rcode mix: mostly NOERROR(0), some NXDOMAIN(3), a few SERVFAIL(2)
RCODES = [0, 0, 0, 0, 0, 0, 0, 3, 3, 2]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", default="127.0.0.1:6001", help="host:port of the dnstap receiver")
    ap.add_argument("--rate", type=float, default=25.0, help="query/response pairs per second")
    ap.add_argument("--duration", type=float, default=60.0, help="seconds to run (ignored if --count)")
    ap.add_argument("--count", type=int, default=0, help="total pairs to send (0 = use --duration)")
    ap.add_argument("--seed", type=int, default=None, help="RNG seed for reproducible traffic")
    args = ap.parse_args(argv)
    if args.seed is not None:
        random.seed(args.seed)

    host, _, port = args.target.rpartition(":")
    sock = socket.create_connection((host, int(port)), timeout=10)
    sock.settimeout(10)

    # Bidirectional handshake: READY → (ACCEPT) → START
    sock.sendall(control_frame(CONTROL_READY, CONTENT_TYPE))
    try:
        ctype = read_control(sock)
        if ctype != CONTROL_ACCEPT:
            print(f"warning: expected ACCEPT(0x01), got 0x{ctype:02x}", file=sys.stderr)
    except socket.timeout:
        print("warning: no ACCEPT within timeout; proceeding anyway", file=sys.stderr)
    sock.sendall(control_frame(CONTROL_START, CONTENT_TYPE))

    interval = 1.0 / args.rate if args.rate > 0 else 0.0
    sent = 0
    start = time.time()
    try:
        while True:
            if args.count and sent >= args.count:
                break
            if not args.count and (time.time() - start) >= args.duration:
                break

            qid = random.randint(0, 0xFFFF)
            qname = random.choice(DOMAINS)
            qtype = QTYPES[random.choice(list(QTYPES))]
            client_ip = f"192.168.1.{random.randint(10, 250)}"
            client_port = random.randint(1024, 65535)
            rcode = 3 if "nonexistent" in qname else random.choice(RCODES)

            q = dns_query(qid, qname, qtype)
            r = dns_response(qid, qname, qtype, rcode)
            sock.sendall(data_frame(dnstap_payload(MSG_CLIENT_QUERY, q, client_ip, client_port)))
            sock.sendall(data_frame(dnstap_payload(MSG_CLIENT_RESPONSE, r, client_ip, client_port)))
            sent += 1
            if interval:
                time.sleep(interval)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            sock.sendall(control_frame(CONTROL_STOP))
            sock.settimeout(3)
            try:
                read_control(sock)  # drain FINISH, if any
            except Exception:
                pass
        finally:
            sock.close()

    elapsed = max(time.time() - start, 1e-6)
    print(f"sent {sent} query/response pairs ({sent * 2} dnstap frames) in {elapsed:.1f}s "
          f"(~{sent / elapsed:.1f} pairs/s) to {args.target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
