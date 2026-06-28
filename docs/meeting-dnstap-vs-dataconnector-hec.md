# Meeting Brief — dnstap → Splunk vs. Infoblox Data Connector → Splunk HEC

**Decision:** Which DNS telemetry pipeline do we standardize on?
**Date:** 2026-06-29 (prep 2026-06-28)
**Audience:** DNS/DDI, Splunk, Security engineering

---

## TL;DR (read this if nothing else)

> The decision is **not** "scp vs HEC" — both modern options terminate at Splunk **HEC**.
> It is **"in-path capture vs out-of-band capture."**
>
> - **HEC is a *transport* upgrade.** It improves how data moves from collector to Splunk (batching, retries, disk buffer, even indexer distribution). It does **nothing** for the reason we turn DNS logging off.
> - **dnstap is a *source* upgrade.** It moves capture off the DNS resolution hot path, so it can run **always-on** and carries **query+response correlation** (60+ fields).
>
> **Confirm one fact before deciding:** *How does the Infoblox Data Connector source DNS query data on the member?* If it requires native DNS query/response logging to be enabled, Option B keeps the full in-path performance tax — HEC just makes the firehose more reliable.

---

## The reframe: two independent axes

The options differ on **two** axes, not one. Separate them:

| | **Transport: syslog file → scp** | **Transport: Data Connector → HEC** |
|---|---|---|
| **Source: native DNS query logging (in-path)** | today's painful baseline | **Option B** (the proposal) |
| **Source: dnstap (out-of-band)** | — | **Option A** (DNSTAP2) |

- The pain today lives at the **source**: native query/response logging runs *inside* the DNS service path. Infoblox's own docs warn it "can adversely affect DNS services and performance" and places "heavy compute demands on the CPU and storage." (`dnstap-value-evidence.md:24-30`, `poc-evaluation-plan.md:19-25`)
- scp → HEC changes only the **transport**. **Option A also terminates at HEC** — A is *not* "the old scp option."

---

## Steelman of Option B (be fair, stay credible)

- **Transport genuinely better than scp:** near-real-time vs batch; retries + disk buffer + ACK; even distribution across indexers; no cron/scp fragility. (`splunk-index-transport-recommendation.md:34-49`)
- **Single-vendor, vendor-supported** data plane — one throat to choke.
- **Operationally familiar** — same `infoblox:dns` sourcetype existing dashboards already parse.
- **No new OSS component** to defend in an architecture/security review.

If Option B's *source* were also out-of-band, it would be a strong contender. Which is why the source question is decisive.

---

## The one question that decides the meeting

**How does the Infoblox Data Connector source DNS query data on the member?**

- **If it requires DNS query/response *logging* enabled** → B carries the full in-path performance tax. HEC didn't save you. **dnstap wins decisively.**
- **If it consumes dnstap / an out-of-band feed** → A and B converge at the source; the debate narrows to "Vector vs Infoblox collector + who operates it."

Our own testing found NIOS emits `CLIENT_QUERY` dnstap regardless of ADP/DCA (`infoblox-dnstap-extract.md:108-136`), so the out-of-band feed exists. Whether the **Data Connector product** uses it — or quietly re-enables query logging — is the unknown. **Walk in with this question answered if possible (see the Infoblox question list).**

---

## Stress-testing "dnstap is better"

**Where the logic is strong:**
1. **Out-of-band → always-on.** Today's core failure: data is "absent exactly when an investigation needs it" because logging gets toggled off. (`dnstap-value-evidence.md:24-30`)
2. **Query+response correlation, 60+ fields** (rcode, latency, RPZ action, full 5-tuple, EDNS/DNSSEC) vs native logging's single query-only line with no response/rcode/timing. (`dnstap-value-evidence.md:301-318`)
3. **Failure isolation:** collector death doesn't stall DNS; HEC down → Vector buffers to disk. (`ARCHITECTURE.md:160-169`)

**Where it's weak (prepare answers, don't get ambushed):**
1. **dnstap produces MORE events → higher Splunk license.** events/s ≈ QPS×2 (up to ×4 recursion-heavy). 5,000 QPS → 12–15k events/s. (`dnstap-collector-sizing.md:32-44`) Have the storage table ready (5k eps → 413 GB/30d *compressed*; raw ~55×). Sampling for high-QPS members is currently out of scope. (`ARCHITECTURE.md:151-158`)
2. **"More complete data" cuts both ways** — value *and* cost. Lead with forensic value; own the volume.
3. **No collector HA today** (single-instance Vector). Answer: disk buffering + DNS keeps serving regardless of collector state.
4. **Operational ownership of Vector.** Answer: one static binary, no JVM/Docker/Python in the data plane. (`ARCHITECTURE.md:58-64`)

---

## Four scenarios

**A — Incident forensics at 2am (DNS exfil suspected). [Open with this.]**
- *Option B (in-path logging):* logging was off for performance → the pre-alert window has **no data**. Even once on, query-only lines (no rcode, no response, no latency).
- *Option A (dnstap):* always-on → prior 30/90 days already in Splunk *with* responses, rcodes, RPZ actions, full 5-tuple. Answered in minutes.

**B — Peak load / capacity.**
- *B:* query logging competes with resolution for CPU/IO at peak QPS → measurable QPS drop/latency (POC T2/T4). Worst case: log disk fills, DNS availability degrades (T7). (`poc-evaluation-plan.md:70-82`)
- *A:* async side-channel; DNS-path overhead "minimal"; overload drops *events*, never *queries*. (`ARCHITECTURE.md:160-169`)

**C — The transport-only win of B, honestly.**
- Concede scp→HEC fully: near-real-time, reliable, load-balanced. Then: "and none of that touched the reason we turn logging off." The reframe lands hardest *because you were fair first.*

**D — Cost & license reality (call it a toss-up).**
- *B:* appliance/VM to size + license; lower event volume (query-only) = lower Splunk GB/day; but in-path tax may force DDI appliance upgrades sooner.
- *A:* no NIOS feature license for dnstap; preserves DDI headroom (TCO *credit*, `poc-evaluation-plan.md:104-110`); higher Splunk volume. Net: **cheaper on DNS capacity, more data per Splunk dollar** — not strictly cheaper. Say so.

---

## Realistic expectations: scp/syslog → Data Connector → HEC

**Will improve:**
- Latency: cron batch (minutes) → near-real-time (seconds).
- Reliability: scp fragility (rotation races, partial transfers, silent gaps) → HEC retries + disk buffer + optional ACK.
- Scaling: per-host scp landing → even distribution across indexers.
- Metadata: index/sourcetype/host per request vs fixed-by-input.

**Will NOT change:**
- DNS member CPU/IO **if the source is still query logging** — zero relief on the core problem.
- Data completeness — still query-only unless dnstap is the source.
- Splunk license GB/day materially — same source volume, just delivered better.

**New things to budget for:**
- HEC token lifecycle + TLS; Splunk often pushes **SC4S** in front for syslog-shaped data. (`splunk-index-transport-recommendation.md:45-49`)
- The Data Connector appliance/VM: sizing, patching, HA, license.
- Indexer ingest headroom for near-real-time bursts (scp smoothed bursts; HEC delivers as they happen).

**Deck one-liner:** *"Switching to HEC is a real, worthwhile reliability/latency upgrade — but it's a transport fix. It changes how we move the data, not whether capturing it costs us DNS performance. Only changing the source (dnstap) does that."*

---

## Objections → rebuttals

| Objection | Rebuttal |
|---|---|
| "Data Connector is vendor-supported; Vector is OSS risk." | Fair on support model. But A is one static binary, no JVM/Docker, and DNS never depends on it. Confirm whether Data Connector re-enables in-path logging — the bigger risk. |
| "HEC modernizes everything, so B is the modern choice." | A *also* ships to HEC. Transport is identical; the source differs. |
| "dnstap will flood Splunk / cost more license." | True, ×2–4 events. Here's the storage table and the sampling lever for high-QPS members. We trade Splunk GB for DNS capacity + always-on forensics. |
| "We already know the syslog dashboards." | A emits the same `infoblox:dns` sourcetype — no dashboard rewrite. (`README.md:119-126`) |
| "Just turn logging on when we need it." | That's the status quo that fails every investigation — data absent exactly when needed. |

---

## Bottom line

> Both modern options use HEC. The real choice is **in-path capture vs out-of-band capture.** HEC leaves the DNS-performance tax untouched; dnstap removes it and adds query+response correlation, at the cost of higher Splunk volume. **Confirm how the Data Connector sources its data — that one fact decides whether B is genuinely different from A, or just A with a different collector.**
