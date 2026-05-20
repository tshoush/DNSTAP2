"""Forward events to Splunk HTTP Event Collector (HEC).

Uses urllib so we have no runtime dependency outside the stdlib. For real
load you'll want batching + an async HTTP client; this is fine for the lab.
"""

from __future__ import annotations

import json
import logging
import ssl
import time
import urllib.error
import urllib.request
from types import TracebackType
from typing import Any

log = logging.getLogger(__name__)


class SplunkHecSink:
    def __init__(
        self,
        *,
        url: str,
        token: str,
        index: str = "dns_dnstap",
        sourcetype: str = "dnstap:json",
        source: str = "dnstap2",
        verify_tls: bool = True,
        timeout: float = 5.0,
    ) -> None:
        self._url = url
        self._token = token
        self._index = index
        self._sourcetype = sourcetype
        self._source = source
        self._timeout = timeout
        self._ctx: ssl.SSLContext | None = None
        if not verify_tls:
            self._ctx = ssl._create_unverified_context()  # noqa: SLF001 — lab only

    def __enter__(self) -> "SplunkHecSink":
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        # Nothing to close — each `write` is a one-shot request.
        return None

    def write(self, event: dict[str, Any]) -> None:
        body = json.dumps(
            {
                "time": time.time(),
                "host": event.get("query_address") or event.get("response_address"),
                "source": self._source,
                "sourcetype": self._sourcetype,
                "index": self._index,
                "event": event,
            },
            separators=(",", ":"),
        ).encode("utf-8")

        req = urllib.request.Request(
            self._url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Splunk {self._token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self._timeout, context=self._ctx):
                pass
        except urllib.error.HTTPError as e:
            log.warning("HEC HTTP %s: %s", e.code, e.read()[:200])
        except urllib.error.URLError as e:
            log.warning("HEC transport error: %s", e)
