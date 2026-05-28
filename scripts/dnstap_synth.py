#!/usr/bin/env python3
"""dnstap_synth.py — synthetic dnstap traffic generator (stdlib only).

Builds valid DNS wire-format query/response packets, wraps each in a dnstap
protobuf message, frames them with the Frame Streams (fstrm) *bidirectional*
handshake, and streams them over TCP to a dnstap receiver (DNS-collector on
:6001 or Vector on :6000). Exercises the pipeline end-to-end — metrics, Loki,
JSONL, Grafana panels — without a real DNS server or InfoBlox.

Produces a realistic mix:
  * client queries/responses        (stub  -> DNS server)   CLIENT_QUERY/RESPONSE
  * recursive resolver queries/resp  (server -> upstream)    RESOLVER_QUERY/RESPONSE
    emitted for a configurable fraction of queries (cache misses)
  * a weighted "top domains" distribution so the most-queried names stand out

Examples:
    python3 scripts/dnstap_synth.py                                 # 25/s, 60s, 50% recursive
    python3 scripts/dnstap_synth.py --rate 40 --duration 7200
    python3 scripts/dnstap_synth.py --recursion-ratio 0.7 --rate 60
    python3 scripts/dnstap_synth.py --count 100 --rate 200          # quick burst
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
MSG_RESOLVER_QUERY = 3      # server -> upstream authoritative (recursion)
MSG_RESOLVER_RESPONSE = 4   # upstream -> server
MSG_CLIENT_QUERY = 5        # stub client -> server
MSG_CLIENT_RESPONSE = 6     # server -> stub client
# message types that carry the query (vs the response) DNS payload
QUERY_TYPES = {MSG_CLIENT_QUERY, MSG_RESOLVER_QUERY}
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
    # flags 0x0100 = QR=0 (query), RD=1 (recursion desired)
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    return header + dns_name(qname) + struct.pack(">HH", qtype, 1)


def dns_response(qid: int, qname: str, qtype: int, rcode: int) -> bytes:
    # flags 0x8180 = QR=1 (response), RD=1, RA=1; low nibble carries rcode
    flags = 0x8180 | (rcode & 0x0F)
    header = struct.pack(">HHHHHH", qid, flags, 1, 0, 0, 0)
    return header + dns_name(qname) + struct.pack(">HH", qtype, 1)


# ── dnstap message + Dnstap wrapper ────────────────────────────────────────
def dnstap_payload(msg_type: int, dns_wire: bytes, peer_ip: str, peer_port: int) -> bytes:
    now = time.time()
    sec = int(now)
    nsec = int((now - sec) * 1e9)

    m = b""
    m += pb_varint(1, msg_type)                      # Message.type
    m += pb_varint(2, SOCKET_FAMILY_INET)            # socket_family
    m += pb_varint(3, SOCKET_PROTOCOL_UDP)           # socket_protocol
    m += pb_bytes(4, socket.inet_aton(peer_ip))      # query_address
    m += pb_varint(6, peer_port)                     # query_port
    if msg_type in QUERY_TYPES:
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


# ── traffic shape ──────────────────────────────────────────────────────────
# Weighted so a handful of names dominate -> a meaningful "Top domains" panel.
WEIGHTED_DOMAINS: list[tuple[str, int]] = [
    ("www.google.com", 100),
    ("login.microsoftonline.com", 85),
    ("teams.microsoft.com", 70),
    ("outlook.office365.com", 60),
    ("marriott.com", 55),
    ("cdn.fastly.net", 42),
    ("s3.amazonaws.com", 36),
    ("api.internal.lab", 30),
    ("mail.google.com", 24),
    ("github.com", 18),
    ("example.com", 12),
    ("time.cloudflare.com", 8),
    ("wpad.corp", 5),
    ("nonexistent-zone.test", 4),     # always NXDOMAIN
    ("typo-domian-xyz.test", 3),      # always NXDOMAIN
]
DOMAINS = [d for d, _ in WEIGHTED_DOMAINS]
WEIGHTS = [w for _, w in WEIGHTED_DOMAINS]
QTYPES = {"A": 1, "AAAA": 28, "MX": 15, "TXT": 16, "CNAME": 5, "PTR": 12, "NS": 2}
# rcode mix: mostly NOERROR(0), some NXDOMAIN(3), a few SERVFAIL(2)
RCODES = [0, 0, 0, 0, 0, 0, 0, 3, 3, 2]

# Weighted client IPs: a few heavy requesters + a long random tail, so the
# "Top clients" panel shows a real ranking. These are the stub clients whose
# cache-miss queries drive the server's recursive (RESOLVER) lookups.
WEIGHTED_CLIENTS: list[tuple[str, int]] = [
    ("192.168.10.21", 100), ("192.168.10.55", 78), ("192.168.20.13", 60),
    ("192.168.30.7", 48), ("192.168.10.99", 36), ("192.168.40.2", 28),
    ("192.168.20.41", 22), ("192.168.50.5", 16), ("192.168.30.88", 11),
    ("192.168.10.12", 8), ("192.168.60.3", 5), ("192.168.40.77", 3),
]
CLIENTS = [c for c, _ in WEIGHTED_CLIENTS]
CLIENT_WEIGHTS = [w for _, w in WEIGHTED_CLIENTS]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", default="127.0.0.1:6001", help="host:port of the dnstap receiver")
    ap.add_argument("--rate", type=float, default=25.0, help="client query/response pairs per second")
    ap.add_argument("--duration", type=float, default=60.0, help="seconds to run (ignored if --count)")
    ap.add_argument("--count", type=int, default=0, help="total client pairs to send (0 = use --duration)")
    ap.add_argument("--recursion-ratio", type=float, default=0.5,
                    help="fraction of queries that also emit a recursive RESOLVER query/response (cache miss)")
    ap.add_argument("--seed", type=int, default=None, help="RNG seed for reproducible traffic")
    args = ap.parse_args(argv)
    if args.seed is not None:
        random.seed(args.seed)
    rec_ratio = max(0.0, min(1.0, args.recursion_ratio))

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
    client_pairs = 0
    resolver_pairs = 0
    start = time.time()
    try:
        while True:
            if args.count and client_pairs >= args.count:
                break
            if not args.count and (time.time() - start) >= args.duration:
                break

            qname = random.choices(DOMAINS, weights=WEIGHTS, k=1)[0]
            qtype = QTYPES[random.choice(list(QTYPES))]
            rcode = 3 if (".test" in qname) else random.choice(RCODES)
            if random.random() < 0.15:   # long tail of occasional clients
                client_ip = f"10.{random.randint(0, 40)}.{random.randint(0, 255)}.{random.randint(1, 254)}"
            else:
                client_ip = random.choices(CLIENTS, weights=CLIENT_WEIGHTS, k=1)[0]
            client_port = random.randint(1024, 65535)
            qid = random.randint(0, 0xFFFF)

            # client side: stub <-> server
            q = dns_query(qid, qname, qtype)
            r = dns_response(qid, qname, qtype, rcode)
            sock.sendall(data_frame(dnstap_payload(MSG_CLIENT_QUERY, q, client_ip, client_port)))
            sock.sendall(data_frame(dnstap_payload(MSG_CLIENT_RESPONSE, r, client_ip, client_port)))
            client_pairs += 1

            # recursive side: server <-> upstream authoritative (cache miss)
            if random.random() < rec_ratio:
                up_ip = f"198.51.100.{random.randint(1, 254)}"   # synthetic upstream auth
                rqid = random.randint(0, 0xFFFF)
                rq = dns_query(rqid, qname, qtype)
                rr = dns_response(rqid, qname, qtype, rcode)
                sock.sendall(data_frame(dnstap_payload(MSG_RESOLVER_QUERY, rq, up_ip, 53)))
                sock.sendall(data_frame(dnstap_payload(MSG_RESOLVER_RESPONSE, rr, up_ip, 53)))
                resolver_pairs += 1

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
    frames = (client_pairs + resolver_pairs) * 2
    print(f"sent {client_pairs} client pairs + {resolver_pairs} recursive pairs "
          f"({frames} dnstap frames) in {elapsed:.1f}s "
          f"(~{client_pairs / elapsed:.1f} client pairs/s) to {args.target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
