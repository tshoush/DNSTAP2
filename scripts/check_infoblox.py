#!/usr/bin/env python3
"""Smoke-test connectivity to the InfoBlox grid master.

Verifies:
  - The WAPI base URL responds.
  - Credentials authenticate.
  - The configured WAPI version matches.
  - The grid master is enumerable.
  - member:dns objects can be listed.
  - The member:dns schema is discoverable and contains dnstap-related fields.

Prints a structured summary and exits non-zero on any failure.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402
from scripts.lib.infoblox import InfobloxClient, WAPIError, discover_dnstap_fields  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml")
    parser.add_argument(
        "--show-schema",
        action="store_true",
        help="print every discovered dnstap-related field's full schema",
    )
    args = parser.parse_args(argv)

    cfg = cfgmod.load(args.config)
    print(f"InfoBlox grid master : {cfg.infoblox.host}")
    print(f"WAPI version         : {cfg.infoblox.wapi_version}")
    print(f"User                 : {cfg.infoblox.username}")
    print(f"TLS verify           : {cfg.infoblox.verify_tls}")
    print("---")

    try:
        client = InfobloxClient(
            host=cfg.infoblox.host,
            username=cfg.infoblox.username,
            password=cfg.infoblox.password,
            wapi_version=cfg.infoblox.wapi_version,
            verify_tls=cfg.infoblox.verify_tls,
            timeout=cfg.infoblox.timeout,
        )
    except WAPIError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 2

    # 1. Grid ping
    try:
        grid = client.ping()
    except WAPIError as e:
        print(f"FAIL: grid ping: {e}", file=sys.stderr)
        return 3
    print(f"grid               : {grid.get('name', '?')} (ref={grid.get('_ref', '?')})")

    # 2. Members
    try:
        members = client.members()
    except WAPIError as e:
        print(f"FAIL: list members: {e}", file=sys.stderr)
        return 4
    print(f"members            : {len(members)}")
    for m in members:
        print(f"  - {m.get('host_name', '?')} ({m.get('platform', '?')})")

    # 3. member:dns enumeration
    try:
        member_dns = client.get_member_dns()
    except WAPIError as e:
        print(f"FAIL: list member:dns: {e}", file=sys.stderr)
        return 5
    md = member_dns.get("members", member_dns)
    md_list = md if isinstance(md, list) else []
    print(f"member:dns objects : {len(md_list)}")

    # 4. Schema discovery for dnstap fields
    try:
        schema = client.schema("member:dns")
    except WAPIError as e:
        print(f"FAIL: fetch schema: {e}", file=sys.stderr)
        return 6
    dnstap_fields = discover_dnstap_fields(schema)
    print(f"dnstap-related schema fields: {len(dnstap_fields)}")
    for fld in dnstap_fields:
        marker = " (struct)" if fld.get("type") in ("struct",) else ""
        print(f"  - {fld.get('name')}{marker}")

    if args.show_schema:
        print("\n--- full dnstap schema ---")
        print(json.dumps(dnstap_fields, indent=2))

    if not dnstap_fields:
        print(
            "WARN: no fields containing 'dnstap' in the schema. Your NIOS build "
            "may not expose dnstap via WAPI. Verify against InfoBlox docs.",
            file=sys.stderr,
        )
        return 7

    print("---\nOK: InfoBlox is reachable and dnstap fields are discoverable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
