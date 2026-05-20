"""Tests for the InfoBlox WAPI client helpers.

These do not hit a real grid master — we exercise the field-discovery and
patch-building logic in isolation.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib.infoblox import InfobloxClient, WAPIError, discover_dnstap_fields  # noqa: E402


def test_discover_dnstap_fields_returns_only_dnstap_names() -> None:
    schema = {
        "fields": [
            {"name": "host_name", "type": "string"},
            {"name": "enable_dnstap_queries", "type": "bool"},
            {"name": "dnstap_setting", "type": "struct"},
            {"name": "ttl", "type": "uint"},
            {"name": "ENABLE_DNSTAP_RESPONSES", "type": "bool"},  # case-insensitive match
        ]
    }
    out = discover_dnstap_fields(schema)
    names = {f["name"] for f in out}
    assert names == {"enable_dnstap_queries", "dnstap_setting", "ENABLE_DNSTAP_RESPONSES"}


def test_discover_dnstap_fields_handles_missing_fields() -> None:
    assert discover_dnstap_fields({}) == []
    assert discover_dnstap_fields({"fields": []}) == []


def test_client_requires_password() -> None:
    with pytest.raises(WAPIError):
        InfobloxClient(host="x", username="u", password="")


def test_client_constructs_base_url() -> None:
    c = InfobloxClient(host="1.2.3.4", username="u", password="p", wapi_version="v2.13.7")
    assert c._base.endswith("/wapi/v2.13.7")  # type: ignore[attr-defined]
