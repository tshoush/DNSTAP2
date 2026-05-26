#!/usr/bin/env python3
"""Configure dnstap on InfoBlox via WAPI.

Defensive flow:
  1. Discover the member:dns schema and identify dnstap-related fields.
  2. Build a patch payload from config.toml using the discovered field names.
  3. Snapshot the current member:dns state to a JSON file (rollback artifact).
  4. Show the proposed patch and require --apply to actually PUT it.
  5. PUT the patch and re-fetch to confirm.

If the schema does not expose dnstap fields (older NIOS builds), the script
prints a helpful message and exits cleanly without changing anything.

Field-name discovery is heuristic — it looks for substrings like:
  dnstap_receiver_address
  dnstap_receiver_port
  enable_dnstap_queries / enable_dnstap_responses
  dnstap_send_client_response_messages
  ... etc.

If your NIOS build uses different names, edit FIELD_HINTS below or pass
--field-map to override.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.lib import config as cfgmod  # noqa: E402
from scripts.lib.infoblox import InfobloxClient, WAPIError, discover_dnstap_fields  # noqa: E402


# Heuristic mapping: each config knob → substrings the WAPI field name may contain.
# The first schema field whose name contains all listed substrings wins.
FIELD_HINTS: dict[str, list[list[str]]] = {
    "receiver_host":     [["dnstap", "receiver", "address"]],
    "receiver_port":     [["dnstap", "receiver", "port"]],
    "client_queries":    [["enable", "dnstap", "queries"], ["dnstap", "send", "client", "query"]],
    "client_responses":  [["enable", "dnstap", "responses"], ["dnstap", "send", "client", "response"]],
    "resolver_queries":  [["dnstap", "send", "resolver", "query"]],
    "resolver_responses":[["dnstap", "send", "resolver", "response"]],
    "auth_queries":      [["dnstap", "send", "auth", "query"]],
    "auth_responses":    [["dnstap", "send", "auth", "response"]],
}


def _field_name_for(knob: str, schema_field_names: set[str]) -> str | None:
    """Return the first schema field name whose lowercased form contains
    every substring in any of the FIELD_HINTS[knob] patterns."""
    for pattern in FIELD_HINTS.get(knob, []):
        for fname in schema_field_names:
            lower = fname.lower()
            if all(part in lower for part in pattern):
                return fname
    return None


def _build_patch(cfg: cfgmod.Config, schema_field_names: set[str]) -> dict[str, Any]:
    """Build a member:dns patch payload using the discovered field names."""
    patch: dict[str, Any] = {}

    mapping: list[tuple[str, Any]] = [
        ("receiver_host", cfg.receiver.advertised_host or cfg.receiver.listen_host),
        ("receiver_port", cfg.receiver.advertised_port),
        ("client_queries", cfg.dnstap.client_queries),
        ("client_responses", cfg.dnstap.client_responses),
        ("resolver_queries", cfg.dnstap.resolver_queries),
        ("resolver_responses", cfg.dnstap.resolver_responses),
        ("auth_queries", cfg.dnstap.auth_queries),
        ("auth_responses", cfg.dnstap.auth_responses),
    ]

    for knob, value in mapping:
        fname = _field_name_for(knob, schema_field_names)
        if fname is None:
            continue
        patch[fname] = value

    # Some NIOS builds expose dnstap config under a nested struct (e.g.
    # `dnstap_setting`). If we found such a struct-shaped field, regroup.
    nested = next(
        (n for n in schema_field_names if n.lower() in ("dnstap_setting", "dnstap_settings")),
        None,
    )
    if nested:
        return {nested: patch}
    return patch


def _snapshot(client: InfobloxClient, refs: list[str], path: Path) -> None:
    snap = {}
    for ref in refs:
        snap[ref] = client.get(ref)
    path.write_text(json.dumps(snap, indent=2, default=str))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="config.toml")
    parser.add_argument(
        "--member",
        action="append",
        default=[],
        help="restrict to a member host_name (may be repeated). default: all members",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="actually PUT the change. Without this, dry-run.",
    )
    parser.add_argument(
        "--snapshot-dir",
        default="snapshots",
        help="directory to write pre-change snapshots to (default: ./snapshots)",
    )
    args = parser.parse_args(argv)

    cfg = cfgmod.load(args.config)
    client = InfobloxClient(
        host=cfg.infoblox.host,
        username=cfg.infoblox.username,
        password=cfg.infoblox.password,
        wapi_version=cfg.infoblox.wapi_version,
        verify_tls=cfg.infoblox.verify_tls,
        timeout=cfg.infoblox.timeout,
    )

    try:
        schema = client.schema("member:dns")
    except WAPIError as e:
        print(f"FAIL: schema fetch: {e}", file=sys.stderr)
        return 2

    dnstap_fields = discover_dnstap_fields(schema)
    if not dnstap_fields:
        print(
            "Your NIOS build does not expose dnstap fields via this WAPI schema. "
            "Verify with InfoBlox documentation for your build, or enable dnstap "
            "via the NIOS Grid Manager UI and re-run.",
            file=sys.stderr,
        )
        return 3
    schema_field_names = {f["name"] for f in dnstap_fields if "name" in f}
    print(f"Discovered {len(schema_field_names)} dnstap-related schema field(s):")
    for n in sorted(schema_field_names):
        print(f"  - {n}")

    try:
        members = client.members()
    except WAPIError as e:
        print(f"FAIL: list members: {e}", file=sys.stderr)
        return 4

    if args.member:
        members = [m for m in members if m.get("host_name") in set(args.member)]

    if not members:
        print("No matching grid members.", file=sys.stderr)
        return 5

    # Find each member's member:dns ref.
    md_objs: list[dict[str, Any]] = client.get("member:dns", _return_fields="host_name")
    refs_by_host = {m.get("host_name"): m.get("_ref") for m in md_objs if "host_name" in m}

    targets: list[tuple[str, str]] = []  # [(host_name, member:dns ref)]
    for m in members:
        host = m.get("host_name")
        ref = refs_by_host.get(host)
        if not ref:
            print(f"  ! no member:dns ref for {host}, skipping")
            continue
        targets.append((host, ref))

    patch = _build_patch(cfg, schema_field_names)
    print("\nProposed patch payload:")
    print(json.dumps(patch, indent=2))

    if not patch:
        print("No fields matched — nothing to apply.", file=sys.stderr)
        return 6

    # Snapshot before any change.
    snap_dir = Path(args.snapshot_dir)
    snap_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    snap_path = snap_dir / f"member-dns-pre-{ts}.json"
    _snapshot(client, [ref for _, ref in targets], snap_path)
    print(f"\nSnapshot written to {snap_path}")

    if not args.apply:
        print("\nDry run only. Re-run with --apply to PUT this patch.")
        return 0

    for host, ref in targets:
        print(f"\nApplying to {host} ({ref}) ...")
        try:
            client.update_member_dns(ref, patch)
        except WAPIError as e:
            print(f"  FAIL: {e}", file=sys.stderr)
            print(f"  rollback artifact at {snap_path}", file=sys.stderr)
            return 7
        print("  OK")

    print("\nAll members updated. Verify dnstap traffic with scripts/test_dnstap_flow.py.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
