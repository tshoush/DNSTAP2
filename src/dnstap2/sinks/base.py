"""Base sink interface."""

from __future__ import annotations

from contextlib import AbstractContextManager
from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class Sink(AbstractContextManager["Sink"], Protocol):
    """A sink consumes decoded dnstap event dicts.

    Sinks are used as context managers so they can hold open files, HTTP
    sessions, etc. and release them cleanly on shutdown.
    """

    def write(self, event: dict[str, Any]) -> None: ...
