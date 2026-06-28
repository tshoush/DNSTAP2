# Questions for Infoblox — Data Connector DNS Sourcing

**Goal:** Resolve the one unknown that decides the dnstap-vs-Data-Connector meeting:
*does the Data Connector pull DNS query data from the in-path logging machinery (performance tax) or from an out-of-band feed?*

Send to Infoblox SE/TAC before the decision meeting.

---

## Critical (these decide the architecture)

1. **Source mechanism:** When the Data Connector collects DNS **query/response** data from a NIOS member, what is the data source on the member? Specifically — does it require **DNS query logging and/or response logging to be enabled** on the member (`member:dns` logging categories), or does it consume an out-of-band feed (e.g., dnstap)?

2. **Performance path:** Does enabling Data Connector DNS data collection place any load **inside the DNS resolution path** (i.e., the same CPU/IO cost Infoblox documents for native query/response logging), or is capture asynchronous/off-path?

3. **dnstap support:** Can the Data Connector ingest **dnstap** (Frame Streams) directly from a NIOS member? If yes, on what NIOS version, and does it require **ADP/DCA**? (Our lab testing shows NIOS emits `CLIENT_QUERY` dnstap regardless of ADP/DCA — does Data Connector rely on that?)

4. **Field completeness:** What DNS fields does Data Connector deliver per event — does it include the **response** (rcode, answer RRs), **query↔response latency**, **RPZ/response-policy action**, full **5-tuple**, and **EDNS/DNSSEC**? Or is it query-only (qname/qtype/client)?

---

## Important (sizing, transport, license)

5. **HEC delivery:** Does Data Connector deliver to Splunk natively over **HEC** (token, HTTPS, batching/retries/ACK), and is **even indexer distribution** supported, or does it land on a single endpoint?

6. **Sourcetype:** What Splunk **sourcetype/format** does it emit — does it match `infoblox:dns` so existing dashboards work unchanged, or a different schema?

7. **Event volume:** At a member doing ~5,000 QPS, roughly how many **events/sec** and **GB/day** should we expect through Data Connector? (For dnstap we model events/s ≈ QPS×2–4.)

8. **Always-on viability:** Is Data Connector DNS collection intended to run **continuously in production**, or is it expected to be toggled per-incident like native logging? Any documented QPS/latency impact at sustained load?

---

## Operational (HA, license, footprint)

9. **HA / scaling:** What is the **HA** model for the Data Connector (active-active? failover?), and what VM/appliance sizing do you recommend for our QPS?

10. **Licensing:** What **NIOS feature license** and/or Data Connector license is required? Any per-member or per-volume component?

11. **Failure isolation:** If the Data Connector or Splunk HEC endpoint is **unreachable**, what happens — does anything back-pressure or affect **DNS service** on the member? Is there on-member buffering, and what are its limits?

12. **TLS:** Is transport from member → Data Connector → Splunk **TLS/mTLS** capable end-to-end?

---

## What "good" answers look like (our decision logic)

- **If Q1/Q2 say it needs in-path logging** → Data Connector keeps the DNS-performance tax; HEC only improves transport. **dnstap (out-of-band) is the better source.**
- **If Q3 says it consumes dnstap off-path** → the two options converge at the source; decision narrows to collector ownership (Vector vs Data Connector) and operability.
- **Either way, Q4 (response correlation) and Q8 (always-on) determine forensic value.**
