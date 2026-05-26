"""Minimal InfoBlox WAPI client.

Stdlib-only. Handles:
  - HTTPS Basic auth against /wapi/<version>/
  - Schema discovery (?_schema=1) so we can find dnstap-related fields without
    hardcoding them
  - GET / PUT / POST helpers with JSON in and out
  - Self-signed cert tolerance (configurable)
"""

from __future__ import annotations

import base64
import json
import logging
import ssl
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

log = logging.getLogger(__name__)


class WAPIError(RuntimeError):
    pass


@dataclass
class WAPIResponse:
    status: int
    body: Any  # decoded JSON


class InfobloxClient:
    def __init__(
        self,
        *,
        host: str,
        username: str,
        password: str,
        wapi_version: str = "v2.13.7",
        verify_tls: bool = False,
        timeout: int = 10,
    ) -> None:
        if not password:
            raise WAPIError(
                "No InfoBlox password provided. Set INFOBLOX_PASSWORD env var or "
                "fill config.toml [infoblox].password (lab only)."
            )
        self._base = f"https://{host}/wapi/{wapi_version}"
        self._auth = base64.b64encode(f"{username}:{password}".encode()).decode()
        self._timeout = timeout
        self._ctx: ssl.SSLContext | None = None
        if not verify_tls:
            self._ctx = ssl._create_unverified_context()  # noqa: SLF001 — lab posture

    # ------------------------------------------------------------------ HTTP

    def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        body: Any | None = None,
    ) -> WAPIResponse:
        url = f"{self._base}/{path.lstrip('/')}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"

        data: bytes | None = None
        headers = {
            "Authorization": f"Basic {self._auth}",
            "Accept": "application/json",
        }
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, method=method, data=data, headers=headers)
        log.debug("%s %s", method, url)
        try:
            with urllib.request.urlopen(req, timeout=self._timeout, context=self._ctx) as resp:
                status = resp.status
                payload = resp.read()
        except urllib.error.HTTPError as e:
            payload = e.read()
            status = e.code
            log.debug("HTTP %s body=%r", status, payload[:300])
            try:
                decoded = json.loads(payload.decode("utf-8") or "null")
            except json.JSONDecodeError:
                decoded = payload.decode("utf-8", errors="replace")
            raise WAPIError(f"{method} {path} → HTTP {status}: {decoded}") from None
        except urllib.error.URLError as e:
            raise WAPIError(f"{method} {path} → transport error: {e}") from None

        try:
            decoded = json.loads(payload.decode("utf-8") or "null")
        except json.JSONDecodeError as e:
            raise WAPIError(f"WAPI returned non-JSON body: {e}") from None
        return WAPIResponse(status=status, body=decoded)

    # --------------------------------------------------------------- helpers

    def get(self, path: str, **params: Any) -> Any:
        return self._request("GET", path, params=params).body

    def put(self, path: str, body: Any) -> Any:
        return self._request("PUT", path, body=body).body

    def post(self, path: str, body: Any) -> Any:
        return self._request("POST", path, body=body).body

    # -------------------------------------------------------- discovery API

    def ping(self) -> dict[str, Any]:
        """Cheap connectivity check — fetch grid info."""
        result = self.get("grid")
        if isinstance(result, list) and result:
            return result[0]
        raise WAPIError(f"unexpected grid response: {result!r}")

    def members(self) -> list[dict[str, Any]]:
        """List grid members."""
        result = self.get("member", _return_fields="host_name,config_addr_type,platform")
        return result if isinstance(result, list) else []

    def get_member_dns(self, member_ref: str | None = None) -> dict[str, Any]:
        """Fetch the member:dns object for `member_ref`, or all members."""
        if member_ref:
            return self.get(f"member:dns/{member_ref}")
        result = self.get("member:dns")
        return {"members": result}

    def schema(self, object_type: str) -> dict[str, Any]:
        """Fetch the WAPI schema for an object type (e.g. 'member:dns').

        Returned dict has a 'fields' key listing every supported field with
        metadata. We use this to discover the dnstap-related fields without
        hardcoding their exact names per NIOS build.
        """
        result = self.get(object_type, _schema=1)
        return result if isinstance(result, dict) else {}

    def update_member_dns(self, member_ref: str, patch: dict[str, Any]) -> Any:
        """PUT a partial update to a member:dns object."""
        return self.put(member_ref, patch)


def discover_dnstap_fields(schema: dict[str, Any]) -> list[dict[str, Any]]:
    """Walk a WAPI schema dict and return fields whose name contains 'dnstap'."""
    out: list[dict[str, Any]] = []
    for fld in schema.get("fields", []):
        name = fld.get("name", "")
        if "dnstap" in name.lower():
            out.append(fld)
    return out
