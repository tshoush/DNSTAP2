"""Write events as JSON to stdout, one per line."""

from __future__ import annotations

import json
import sys
from types import TracebackType
from typing import Any


class StdoutSink:
    def __enter__(self) -> "StdoutSink":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        sys.stdout.flush()

    def write(self, event: dict[str, Any]) -> None:
        sys.stdout.write(json.dumps(event, separators=(",", ":")))
        sys.stdout.write("\n")
        sys.stdout.flush()
