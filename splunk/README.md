# Splunk dashboards

Ready-to-import Splunk **Classic (Simple XML)** dashboards for DNS dnstap
telemetry. Pick by which **index** your events land in and what you want to do.

| File | Index / format | Splits by | Purpose |
|---|---|---|---|
| [`dns_dnstap_overview.xml`](dns_dnstap_overview.xml) | `dns_dnstap`, `sourcetype=dnscollector:json` (flat-json) | `dnstap.identity` (DNS server) | Rich overview: QPS, top domains, rogue-client / DDoS hunting, cache-hit %, NXDOMAIN, latency. Uses native JSON fields. |
| [`dns_dnstap_ab_overview.xml`](dns_dnstap_ab_overview.xml) | `mi_dhcp` (UF text lines) | `source` (receiver) | Port of the Grafana "DNS-collector Overview (+ A/B vs Vector)" board. Compares **Vector (`:6000`)** vs **DNS-collector (`:6001`)** side by side. |
| [`dns_dnstap_filterable.xml`](dns_dnstap_filterable.xml) | `mi_dhcp` (UF text lines) | `source` (receiver) | Same data with interactive filters: **Receiver / DNS leg / domain / client IP** + time + granularity. Click pie/table rows to drill down. |
| [`infoblox_system_health.xml`](infoblox_system_health.xml) | `mi_dhcp`, `sourcetype=infoblox:health` (UF `key=value`) | `member` | **System health** (optional add-on): CPU / Memory / Swap / Disk gauges, load & uptime trends, and a per-member status table — the InfoBlox Grid Manager "System" view. Fed by [`scripts/poc_health_snmp.py`](../scripts/poc_health_snmp.py) over SNMP. |

## Which index do I have?

- **`dns_dnstap`** — events arrive as **flat-json** (HEC, or a syslog/SC4S input).
  Fields like `dnstap.identity`, `dnstap.operation`, `dns.rcode`, `network.query-ip`
  are extracted by Splunk automatically. Use `dns_dnstap_overview.xml`.
- **`mi_dhcp`** — events arrive as **NIOS-style text lines** shipped by a Splunk
  Universal Forwarder monitoring `nios.log` (the POC path; the indexer only
  exposes an S2S/splunktcp input). Fields are **not** pre-extracted, so the two
  `mi_dhcp` dashboards do search-time `rex` on `_raw`. Use `dns_dnstap_ab_overview.xml`
  or `dns_dnstap_filterable.xml`.

## Vector vs DNS-collector (the A/B split)

In the `mi_dhcp` path both receivers write to the same index, distinguished by
the `source` field set in the UF monitor stanza:

| Receiver | `source` | dnstap port | line format |
|---|---|---|---|
| Vector | `dnstap:vector` | `:6000` | `client <ip>#<port>` (byte-exact NIOS) |
| DNS-collector | `dnstap:dnscollector` | `:6001` | `client <ip> <port>` (space-separated) |

Filter / split on `source` (or the `receiver` eval the dashboards add). The
search-time extractions handle **both** line formats and **both** the
`CLIENT_*` (client-facing) and `RESOLVER_*` (recursion) legs — the DNS-leg
filter defaults to client-facing so per-second rates aren't inflated by counting
the resolver leg.

Quick A/B sanity check in the search bar:

```spl
index=mi_dhcp source IN ("dnstap:vector","dnstap:dnscollector") earliest=-15m
| eval receiver=case(source="dnstap:vector","Vector",source="dnstap:dnscollector","DNS-collector",true(),source)
| stats count, max(_time) as last by receiver | convert ctime(last)
```

## Importing

**Splunk UI:** Dashboards → Create New Dashboard → **Classic** → name it →
**Source** (`</>`) → delete the stub → paste the whole XML file → **Save**.
(Paste XML only into the *Source* editor, never the search bar.)

**REST API:**

```bash
curl -k -u <user>:<pass> \
  https://<splunk-host>:8089/servicesNS/admin/search/data/ui/views \
  -d "name=dns_dnstap_filterable" \
  --data-urlencode "eai:data@dns_dnstap_filterable.xml"
```

## Optional: InfoBlox system health (SNMP)

A separate, optional feed adds host/member **system-health** metrics (CPU,
memory, swap, disk, load, uptime) next to the dnstap data in the same index —
the things the InfoBlox Grid Manager "System" panel shows.

```bash
# collect every 60s into a UF-monitored log (SNMP poll of an InfoBlox member):
HEALTH_TARGET=172.25.15.234 SNMP_COMMUNITY=public sudo -E ./scripts/install_health_snmp.sh
# add the UF monitor for the health file (one time):
HEALTH_LOG_PATH=/var/log/dnstap-health/health.log sudo -E ./scripts/install_splunk_uf.sh
```

The collector ([`scripts/poc_health_snmp.py`](../scripts/poc_health_snmp.py))
emits Splunk `key=value` lines (`sourcetype=infoblox:health`,
`source=infoblox:health`), so every field auto-extracts. `--self` mode reads the
local `/proc` instead of SNMP (monitor the collector box itself, or test without
an agent). Sanity check:

```spl
index=mi_dhcp sourcetype="infoblox:health" earliest=-1h
| stats latest(health_status) as status latest(cpu_used_pct) as cpu
        latest(mem_used_pct) as mem latest(disk_used_pct) as disk by member
```

## Notes

- The `mi_dhcp` `rex` patterns are derived from the two receiver line formats; if
  a future NIOS/Vector/DNS-collector build changes the line, a panel may come up
  empty — re-check with the sanity query above and adjust the `rex`.
- `tests/test_splunk_dashboards.py` validates these files stay well-formed and
  keep referencing the expected index/source values.
