# Recommendation — Splunk index & transport for DNSTap (InfoBlox)

**Context:** InfoBlox `.222` emits dnstap → Vector (receiver `.50:6000`) renders the
exact NIOS query-log syslog lines → Splunk. Two paths exist today:
raw-socket (no-auth) → index `mi_dhcp`, and HEC → index `dns_dnstap`. Question:
one index or two, and which transport — grounded in Splunk's documented best
practices. Requirement: **keep the no-auth syslog route intact.**

## TL;DR

- **Use ONE index: `dns_dnstap`.** Differentiate feeds by `sourcetype`/`source`,
  not by index.
- **Lab / current:** keep the **no-auth syslog** (raw `:5514`) route as the live
  feed → `dns_dnstap`.
- **Production:** deliver into Splunk via **HEC** → same `dns_dnstap` index.
- Run **one transport at a time** into the shared index (same data over both =
  duplicate events). The other stays configured but disabled as a fallback.

## 1. One index, not two (Splunk best practice)

Splunk guidance: keep **as few indexes as you can manage**; split indexes only for
**different retention, access control, or very different volumes** — *not* to make
searches/dashboards easier ("using different indexes only to simplify searches is
overkill"). Differentiate by **sourcetype/source**.

For us: the DNSTap data is identical regardless of transport, so two indexes is an
anti-pattern. Standardize on **`dns_dnstap`** because:
- it's the repo default (`config.example.toml`, the installer `SPLUNK_INDEX`), and
- the **shipped dashboard `splunk/dns_dnstap_overview.xml`** already queries
  `index=dns_dnstap` (15 panels) — instant dashboard reuse.

(`mi_dhcp` was a one-off name from lab setup and a confusing label for DNS data.)

## 2. Transport: raw socket (lab) vs HEC (production)

| | Raw socket `:5514` (no-auth) | HEC `:8088` |
|---|---|---|
| Auth | none | token (HTTPS) |
| Delivery | fire-and-forget TCP/UDP | batched, **retries + disk buffer + healthcheck**, optional ACK |
| Metadata | fixed by the input config | set per request (index/sourcetype/source/host) |
| Distribution | per-connection, no LB | even distribution across indexers |
| Splunk Cloud | not accepted | required |
| Splunk stance | **"acceptable for lab/test" only** | production-grade |

Splunk **strongly discourages raw TCP/UDP inputs straight into an indexer in
production**; the documented best practice for syslog is **SC4S (Splunk Connect for
Syslog)** — which itself receives plain syslog at the edge (**no auth**) and then
**delivers to Splunk over HEC**. So *no-auth-syslog-in + HEC-into-Splunk* is the
recommended architecture.

## 3. Where "no-auth" actually lives (it is preserved)

The HEC token sits **only on the Vector → Splunk hop**. The DNS sources stay
unauthenticated: InfoBlox `.222 → Vector` (dnstap) and any syslog devices →
Vector/SC4S carry no auth. Moving to HEC does **not** push auth back onto the DNS
sources.

## 4. Recommended end-state

**Lab (now):**
`InfoBlox .222 → Vector .50:6000 → raw socket :5514 (no-auth) → index dns_dnstap`
HEC sink configured but disabled (standby). Dashboards on `dns_dnstap`.

**Production:**
`InfoBlox .222 → Vector → HEC → index dns_dnstap` (token only Vector↔Splunk).
Same index, same `sourcetype=infoblox:dns`, **same dashboards** — you just flip the
active transport from raw-socket to HEC.

> Note: we already have Vector (a collector with disk buffering + retry that speaks
> HEC), so a separate **SC4S** tier isn't required. SC4S earns its keep only when
> many raw appliances syslog directly with no collector in front. For raw-device
> syslog at scale, the production edge would be SC4S → HEC → `dns_dnstap`.

## 5. Action items to consolidate (keeping syslog intact)

1. Repoint the raw `:5514` Splunk input from `mi_dhcp` → `dns_dnstap`.
2. Keep the no-auth syslog sink active; keep the HEC sink configured but disabled
   (avoid duplicate indexing).
3. Point dashboards at `dns_dnstap` (reuse `splunk/dns_dnstap_overview.xml`).
4. Retire the empty `mi_dhcp` index.
5. For production: flip Vector's active sink to HEC (same `dns_dnstap`).

## Sources

- Splunk Community — Index strategy, single vs multiple indexes:
  https://community.splunk.com/t5/Getting-Data-In/Index-Strategy-Single-index-with-multiple-sourcetypes-vs/m-p/240018
- Splunk Community — Indexes/Source Types best practice (data onboarding):
  https://community.splunk.com/t5/Getting-Data-In/Indexes-Source-Types-Best-Practice-Data-Onboarding/m-p/625553
- Splunk Lantern — Data collection architecture:
  https://lantern.splunk.com/Splunk_Success_Framework/Platform_Management/Data_collection_architecture
- Splunk Connect for Syslog — Architecture:
  https://splunk.github.io/splunk-connect-for-syslog/main/architecture/
- Splunk Community — SC4S vs syslog server tier:
  https://community.splunk.com/t5/Deployment-Architecture/SC4S-vs-syslog-servers-tier/m-p/752676
