#!/usr/bin/env python3
"""Read-only diagnostic: why isn't a NIOS member streaming dnstap?

Self-contained + Python-3.6-safe (runs under RHEL 7.9 stock /usr/bin/python3).
Stdlib only, no third-party deps, no `scripts.lib` import — so it can be cloned
and run anywhere, including the POC box (.234).

Pulls the *actual* config from the grid via WAPI (GET only — never writes) and
reports on every known prerequisite for dnstap streaming:

  1. Connectivity + member list
  2. Does this NIOS build expose dnstap fields at all? (member:dns schema)
  3. The target member's DNS-enabled state, dnstap settings, DCA state
  4. Advanced DNS Protection (ADP / Threat Protection) state on the member
  5. Licenses present in the grid (DNS / Threat Protection / DCA / RPZ)
  6. Cross-member correlation: who has dnstap on, who has ADP on

Usage:
  INFOBLOX_PASSWORD=... python3 diagnose_dnstap_prereqs.py \
      --host 162.130.128.10 --user apitestuser --member awsclddi01w

Nothing here mutates the grid; safe to run against production.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


class WAPIError(RuntimeError):
    pass


class InfobloxClient:
    """Minimal stdlib-only WAPI client (GET/PUT/POST), self-signed tolerant."""

    def __init__(self, host, username, password, wapi_version="v2.13.7",
                 verify_tls=False, timeout=20):
        if not password:
            raise WAPIError(
                "No InfoBlox password provided. Set INFOBLOX_PASSWORD env var "
                "or pass --password (lab only)."
            )
        self._base = "https://{0}/wapi/{1}".format(host, wapi_version)
        self._auth = base64.b64encode(
            "{0}:{1}".format(username, password).encode()
        ).decode()
        self._timeout = timeout
        self._ctx = None
        if not verify_tls:
            self._ctx = ssl._create_unverified_context()

    def get(self, path, **params):
        url = "{0}/{1}".format(self._base, path.lstrip("/"))
        if params:
            url = "{0}?{1}".format(url, urllib.parse.urlencode(params))
        headers = {
            "Authorization": "Basic {0}".format(self._auth),
            "Accept": "application/json",
        }
        req = urllib.request.Request(url, method="GET", headers=headers)
        try:
            with urllib.request.urlopen(
                req, timeout=self._timeout, context=self._ctx
            ) as resp:
                payload = resp.read()
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            raise WAPIError("GET {0} -> HTTP {1}: {2}".format(path, e.code, body[:300]))
        except urllib.error.URLError as e:
            raise WAPIError("GET {0} -> transport error: {1}".format(path, e))
        return json.loads(payload.decode("utf-8") or "null")


def hdr(title):
    print("\n{0}\n{1}\n{2}".format("=" * 70, title, "=" * 70))


def grep_fields(schema, *needles):
    out = []
    for fld in schema.get("fields", []):
        name = fld.get("name", "")
        low = name.lower()
        if any(n in low for n in needles):
            out.append(name)
    return sorted(out)


def show(obj, keys):
    for k in sorted(keys):
        if k in obj:
            print("   {0} = {1!r}".format(k, obj[k]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True, help="grid master IP/hostname")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--member", help="member host_name (short name ok; regex match)")
    ap.add_argument("--password", default=os.environ.get("INFOBLOX_PASSWORD", ""),
                    help="WAPI password (prefer the INFOBLOX_PASSWORD env var)")
    ap.add_argument("--wapi-version", default="v2.13.7")
    args = ap.parse_args()

    client = InfobloxClient(
        host=args.host, username=args.user, password=args.password,
        wapi_version=args.wapi_version, verify_tls=False, timeout=20,
    )

    # 1 -------------------------------------------------------------- connectivity
    hdr("1. Connectivity / members")
    try:
        members = client.get("member", _return_fields="host_name")
    except WAPIError as e:
        print("   CONNECT FAILED: {0}".format(e))
        return 2
    names = [m.get("host_name", "?") for m in members]
    print("   connected OK; grid has {0} member(s)".format(len(names)))

    # 2 -------------------------------------------------------- dnstap schema support
    hdr("2. Does this NIOS build expose dnstap fields? (member:dns schema)")
    dns_schema = client.get("member:dns", _schema=1)
    if not isinstance(dns_schema, dict):
        dns_schema = {}
    dnstap_field_names = [
        f.get("name") for f in dns_schema.get("fields", [])
        if "dnstap" in f.get("name", "").lower()
    ]
    if not dnstap_field_names:
        print("   !! NO dnstap fields in member:dns schema — this NIOS build/WAPI "
              "version does not expose dnstap config.")
    else:
        print("   {0} dnstap field(s): {1}".format(
            len(dnstap_field_names), ", ".join(dnstap_field_names)))
    cache_fields = grep_fields(dns_schema, "cache_accel", "dca", "accel")
    if cache_fields:
        print("   cache-acceleration fields: {0}".format(cache_fields))

    # 3 ------------------------------------------------- member dns object + dnstap state
    hdr("3. Target member: DNS enabled? dnstap + DCA state? (member:dns)")
    if not args.member:
        print("   (no --member given; skipping member-specific checks)")
    else:
        rf = ",".join(["host_name", "enable_dns"] + dnstap_field_names + cache_fields)
        try:
            md = client.get("member:dns", **{"host_name~": args.member, "_return_fields": rf})
        except WAPIError as e:
            print("   member:dns query failed: {0}".format(e))
            md = []
        if not md:
            print("   (no member:dns object matched {0!r})".format(args.member))
        for m in md:
            print("\n   --- member {0} ---".format(m.get("host_name", "?")))
            print("   enable_dns = {0!r}".format(m.get("enable_dns")))
            print("   -- dnstap --")
            show(m, dnstap_field_names)
            print("   -- dns cache acceleration --")
            show(m, cache_fields)

        # 4 ------------------------------------------------- ADP / threat protection
        hdr("4. Advanced DNS Protection / Threat Protection on the member")
        # host_name on member:threatprotection requires EXACT match (no '~').
        full = next((n for n in names if args.member in n), args.member)
        try:
            tp = client.get("member:threatprotection", host_name=full,
                            _return_fields="host_name,enable_service")
            if tp:
                print("   {0}".format(tp))
            else:
                print("   member:threatprotection = [] -> ADP NOT enabled on {0}".format(full))
        except WAPIError as e:
            print("   member:threatprotection: {0}".format(str(e)[:200]))

    # 5 ----------------------------------------------------------------- licenses
    hdr("5. Licenses present in the grid (distinct types)")
    try:
        lic = client.get("member:license", _return_fields="type")
        types = sorted({str(r.get("type")) for r in lic})
        print("   {0} license rows; distinct types: {1}".format(len(lic), types))
        tp_like = [t for t in types if any(k in t.lower()
                   for k in ("tp", "threat", "adp"))]
        dca_like = [t for t in types if any(k in t.lower()
                    for k in ("dca", "cache", "accel"))]
        print("   threat-protection-ish license types: {0}".format(tp_like or "NONE"))
        print("   dca/cache-ish license types:         {0}".format(dca_like or "NONE"))
    except WAPIError as e:
        print("   member:license: {0}".format(str(e)[:200]))

    # 6 ------------------------------------------ correlation: dnstap-on vs ADP-on
    hdr("6. Correlation across members: dnstap-on vs ADP-on")
    try:
        md_all = client.get("member:dns",
                            _return_fields="host_name,enable_dnstap_queries,"
                                           "enable_dnstap_responses,dnstap_setting,"
                                           "enable_dns_cache_acceleration",
                            _max_results=500)
        dnstap_on = []
        for m in md_all:
            if m.get("enable_dnstap_queries") or m.get("enable_dnstap_responses"):
                s = m.get("dnstap_setting") or {}
                dnstap_on.append((m["host_name"],
                                  s.get("dnstap_receiver_address_or_fqdn"),
                                  s.get("dnstap_receiver_port"),
                                  m.get("enable_dns_cache_acceleration")))
        print("   members with dnstap enabled: {0}/{1}".format(len(dnstap_on), len(md_all)))
        for h, addr, port, dca in dnstap_on:
            print("      {0} -> {1}:{2}  DCA={3}".format(h, addr, port, dca))
    except WAPIError as e:
        print("   member:dns sweep: {0}".format(str(e)[:200]))
    try:
        tp_all = client.get("member:threatprotection",
                            _return_fields="host_name,enable_service", _max_results=500)
        adp_on = [t["host_name"] for t in tp_all if t.get("enable_service")]
        print("   members with ADP enabled: {0}".format(len(adp_on)))
        for h in adp_on:
            print("      {0}".format(h))
    except WAPIError as e:
        print("   member:threatprotection sweep: {0}".format(str(e)[:200]))

    print("\nDone (read-only; nothing was modified).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
