"""dnstap payload decoder.

This is intentionally a STUB. The framing layer (`framestream.py`) yields
opaque dnstap protobuf payloads; turning those into structured records
requires the canonical `dnstap.proto` schema.

To wire in the real decoder:

1. Get `dnstap.proto` from https://github.com/dnstap/dnstap.pb
2. Compile it:
       pip install protobuf grpcio-tools
       python -m grpc_tools.protoc -Iproto --python_out=src/dnstap2/_pb proto/dnstap.proto
3. Replace `decode_frame` below with a call to the generated `Dnstap` message
   and project out the fields you care about (client IP, qname, qtype, rcode,
   timing, etc.).

Until then, this stub returns a placeholder dict that is enough to prove the
pipeline plumbing works end-to-end (frames flow, sinks receive them).
"""

from __future__ import annotations

import hashlib
from typing import Any


def decode_frame(payload: bytes) -> dict[str, Any]:
    """Decode a dnstap protobuf payload into a structured dict.

    STUB IMPLEMENTATION. See module docstring for how to plug in the real one.
    """
    return {
        "raw_bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "_decoded": False,
        "_note": "stub decoder — see decoder.py docstring to enable full decoding",
    }
