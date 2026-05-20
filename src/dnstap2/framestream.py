"""Frame Streams (fstrm) — minimal unidirectional content-stream reader.

Reference: https://farsightsec.github.io/fstrm/

Wire format
-----------
A Frame Streams stream is a sequence of frames. Each frame is prefixed with a
4-byte big-endian length:

    +--------------------+-------------------------+
    | length (uint32 BE) | payload (length bytes)  |
    +--------------------+-------------------------+

A length of 0 introduces a *control frame*. The control frame itself has its
own length prefix immediately after the zero:

    +--------+----------------------+----------------------------+
    | 0x0000 | ctl_length (u32 BE)  | control payload (...)      |
    +--------+----------------------+----------------------------+

Control frame payload starts with a control-type field (u32 BE):

    START   = 0x01
    STOP    = 0x03
    READY   = 0x04   (bidirectional only)
    ACCEPT  = 0x05   (bidirectional only)
    FINISH  = 0x05   ... see spec; we only need START/STOP for unidirectional

For unidirectional content streams (what `dnstap-output unix ...` produces by
default) the producer sends: START → N data frames → STOP. We implement just
this case here; it is enough for InfoBlox / BIND / Unbound default emission.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import BinaryIO, Iterator

CONTROL_ACCEPT = 0x01
CONTROL_START = 0x02
CONTROL_STOP = 0x03
CONTROL_READY = 0x04
CONTROL_FINISH = 0x05

# dnstap "content type" string emitted in the START control frame.
DNSTAP_CONTENT_TYPE = b"protobuf:dnstap.Dnstap"


class FrameStreamError(Exception):
    """Raised on protocol violations or short reads."""


@dataclass
class StreamHeader:
    """Parsed information from the START control frame."""

    content_type: bytes | None


def _read_exact(stream: BinaryIO, n: int) -> bytes:
    """Read exactly `n` bytes from `stream` or raise on EOF."""
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            raise FrameStreamError(
                f"unexpected EOF: wanted {n} bytes, got {len(buf)}"
            )
        buf.extend(chunk)
    return bytes(buf)


def _parse_control(payload: bytes) -> tuple[int, dict[int, bytes]]:
    """Parse a control-frame payload into (control_type, fields_by_id)."""
    if len(payload) < 4:
        raise FrameStreamError("control frame shorter than 4 bytes")
    (ctype,) = struct.unpack(">I", payload[:4])
    fields: dict[int, bytes] = {}
    i = 4
    while i < len(payload):
        if i + 8 > len(payload):
            raise FrameStreamError("truncated control field header")
        field_type, field_len = struct.unpack(">II", payload[i : i + 8])
        i += 8
        if i + field_len > len(payload):
            raise FrameStreamError("truncated control field value")
        fields[field_type] = payload[i : i + field_len]
        i += field_len
    return ctype, fields


def iter_frames(stream: BinaryIO) -> Iterator[bytes]:
    """Yield raw data-frame payloads from a Frame Streams unidirectional stream.

    Consumes the START control frame, yields each data frame's bytes, and
    returns cleanly when the STOP control frame is received or the stream
    closes.
    """
    header_seen = False
    while True:
        try:
            (length,) = struct.unpack(">I", _read_exact(stream, 4))
        except FrameStreamError:
            # Clean EOF before any START — treat as empty stream.
            return

        if length == 0:
            # Control frame follows.
            try:
                (ctl_len,) = struct.unpack(">I", _read_exact(stream, 4))
            except FrameStreamError as e:
                raise FrameStreamError(f"truncated control length: {e}") from e
            payload = _read_exact(stream, ctl_len)
            ctype, fields = _parse_control(payload)
            if ctype == CONTROL_START:
                header_seen = True
                # content type is field id 0x01 per fstrm
                _ = fields.get(0x01)
                continue
            if ctype == CONTROL_STOP:
                return
            # READY/ACCEPT/FINISH are bidirectional-only; tolerate but ignore.
            continue

        if not header_seen:
            raise FrameStreamError("data frame received before START control frame")
        yield _read_exact(stream, length)
