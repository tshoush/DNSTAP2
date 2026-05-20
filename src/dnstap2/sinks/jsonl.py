"""Append events as JSON lines to a file."""

from __future__ import annotations

import json
from pathlib import Path
from types import TracebackType
from typing import Any, TextIO


class JsonlSink:
    def __init__(self, path: str | Path) -> None:
        self._path = Path(path)
        self._fp: TextIO | None = None

    def __enter__(self) -> "JsonlSink":
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._fp = self._path.open("a", encoding="utf-8")
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        if self._fp is not None:
            self._fp.flush()
            self._fp.close()
            self._fp = None

    def write(self, event: dict[str, Any]) -> None:
        assert self._fp is not None, "sink used outside its context manager"
        self._fp.write(json.dumps(event, separators=(",", ":")))
        self._fp.write("\n")
