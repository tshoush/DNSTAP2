"""Smoke tests for the Frame Streams reader."""

from __future__ import annotations

import io
import struct

import pytest

from dnstap2 import framestream


def _u32(n: int) -> bytes:
    return struct.pack(">I", n)


def _control(ctype: int, fields: dict[int, bytes] | None = None) -> bytes:
    payload = _u32(ctype)
    for fid, val in (fields or {}).items():
        payload += _u32(fid) + _u32(len(val)) + val
    return _u32(0) + _u32(len(payload)) + payload


def _data(payload: bytes) -> bytes:
    return _u32(len(payload)) + payload


def test_empty_stream_returns_no_frames() -> None:
    stream = io.BytesIO(b"")
    assert list(framestream.iter_frames(stream)) == []


def test_start_then_data_then_stop() -> None:
    buf = io.BytesIO(
        _control(framestream.CONTROL_START, {0x01: framestream.DNSTAP_CONTENT_TYPE})
        + _data(b"hello")
        + _data(b"world")
        + _control(framestream.CONTROL_STOP)
    )
    assert list(framestream.iter_frames(buf)) == [b"hello", b"world"]


def test_data_before_start_raises() -> None:
    buf = io.BytesIO(_data(b"oops"))
    with pytest.raises(framestream.FrameStreamError):
        list(framestream.iter_frames(buf))


def test_truncated_data_frame_raises() -> None:
    buf = io.BytesIO(
        _control(framestream.CONTROL_START) + _u32(10) + b"short"
    )
    with pytest.raises(framestream.FrameStreamError):
        list(framestream.iter_frames(buf))


def test_unknown_control_is_tolerated() -> None:
    buf = io.BytesIO(
        _control(framestream.CONTROL_START)
        + _control(framestream.CONTROL_READY)  # bidirectional-only; ignored
        + _data(b"payload")
        + _control(framestream.CONTROL_STOP)
    )
    assert list(framestream.iter_frames(buf)) == [b"payload"]
