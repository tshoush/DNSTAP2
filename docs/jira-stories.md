# Jira Backlog — DNS Logging vs. dnstap POC

Execution backlog for [poc-evaluation-plan.md](poc-evaluation-plan.md). Six epics, 19
stories. Story points are Fibonacci; priority is the business urgency of the result.
A ready-to-import CSV is in [jira-stories.csv](jira-stories.csv).

**Labels:** `dns-poc`, `dnstap`, `infoblox`, `performance`, `security`, `cost`.

---

## EPIC A — POC Environment & Baseline
*Goal: a controlled lab where only the logging mode varies, with trustworthy instrumentation.*

### A1 · Stand up POC lab and load generator
**As** the POC team **I want** a non-prod NIOS member plus a dedicated load-generator host
**so that** I can drive repeatable DNS load without the generator stealing the member's CPU.
**AC:** lab NIOS member identified/built; generator host with `dnsperf` + `dnstrace`
installed on a separate box; DNSTAP2 collector stack reachable; network path
`member→collector:6001` open; topology documented. **SP 3 · High**

### A2 · Define load profiles and query mix
**AC:** P1 steady, P2 peak, P3 bursty, P4 soak profiles defined with target QPS; query mix
includes cache-hit, cache-miss/recursion, NXDOMAIN, realistic qtype/qname distribution;
mix file checked into the repo; method to replay identically across runs. **SP 2 · High**

### A3 · Instrument member + collector resource capture
**AC:** member CPU/mem/IO captured during runs (node_exporter or NIOS `ibPlatformOne` SNMP);
collector/Prometheus/Loki resource use captured; results sheet schema defined keyed by
(test, mode, profile, run#). **SP 2 · Medium**

---

## EPIC B — Performance Testing (the core question)
*Goal: quantify the DNS performance penalty of native logging vs dnstap.*

### B1 · Measure baseline DNS performance (no logging) — T1
**AC:** ramp QPS to SLA-break; record max sustainable QPS, p50/p95/p99 latency, member
CPU/mem/IO; ≥3 runs, medians reported; baseline frozen as the reference. **SP 3 · High**

### B2 · Measure native query-logging performance — T2
**AC:** repeat all profiles with NIOS logging in 3 modes (queries; responses; both); report
% QPS drop, latency delta, CPU/IO delta vs baseline for each mode; confirm/refute Infoblox's
"don't run both" guidance with data. **SP 5 · High**

### B3 · Measure dnstap performance — T3
**AC:** repeat all profiles with dnstap→collector enabled and native logging off; report
QPS/latency/CPU deltas vs baseline; confirm events arrive at the collector during load. **SP 3 · High**

### B4 · Head-to-head delta analysis — T4
**AC:** charted comparison native vs dnstap vs baseline at P2 peak; explicit statement of
performance penalty for each and which preserves more DNS headroom; feeds scorecard C1. **SP 3 · High**

---

## EPIC C — Data Quality & Forensics
*Goal: prove which option actually answers the security/ops questions.*

### C1 · Data completeness & fidelity comparison — T5
**AC:** sample N queries through each path; verify dnstap correlates query+response, shows
recursion (RESOLVER_*), and captures client IP/qname/qtype/rcode/timing; document what native
logging captures and any gaps (e.g. response not bundled with query). **SP 3 · High**

### C2 · Security / forensics query evaluation — T10
**AC:** run representative threat-hunt queries on each dataset (DNS-tunneling via TXT/NULL/ANY
volume, NXDOMAIN/DGA spikes, per-client domain history) in Loki/Splunk; record which option
can answer each and how easily; feeds scorecard C6. **SP 5 · High**

---

## EPIC D — Scale, Resilience & Storage
*Goal: confirm "always-on" is actually safe and affordable at production scale.*

### D1 · Soak / sustained-scale test — T6
**AC:** run P4 (2–4 h) under native and under dnstap; show no CPU creep, memory leak, or
latency drift; collector keeps up; member stays stable throughout. **SP 3 · Medium**

### D2 · Failure modes & backpressure — T7
**AC:** under load, kill the collector and drop the network; **prove DNS resolution stays
healthy** (latency/availability unaffected); characterize dnstap buffer/drop behavior and
native logging's disk-full/IO-stall behavior; document worst case. **SP 5 · High**

### D3 · Storage volume & growth model — T8
**AC:** measure bytes/event and rate at P1/P2 for each option; project GB/day at production
QPS and storage for 30/90/365-day retention; note compression; feeds TCO + scorecard C5. **SP 3 · High**

### D4 · Collector pipeline throughput — T9 (dnstap)
**AC:** drive the collector to its event-rate ceiling; report max events/s before drop,
Prometheus/Loki ingest headroom, Grafana responsiveness, telemetry-host resource use; sizing
guidance + HA recommendation. **SP 3 · Medium**

### D5 · Interface & network validation — T11
**AC:** validate dnstap egress over LAN1 vs MGMT (out-of-band); confirm single firewall rule
`DNS→collector:6001`; confirm no data-plane coupling. **SP 2 · Medium**

---

## EPIC E — Cost & Implementation Analysis
*Goal: the business case and the rollout plan.*

### E1 · 3-year TCO model (both options) — §4
**AC:** tabulate appliance/headroom impact, feature licensing (incl. Data Connector VM if
modeled), storage ($/GB × retention × GB/day from D3), SIEM ingest, and FTE/ops over 3 years
for native vs dnstap; credit dnstap with any deferred-upgrade cost avoidance; reviewed by
finance/procurement. **SP 5 · High**

### E2 · Implementation & day-2 operations plan — §5
**AC:** phased per-member rollout via the InfoBlox Ops playbook; collector HA/sizing; retention
policy; SIEM integration; alerting + dashboards; telemetry-host monitoring; change-window and
restart guidance; rollback procedure. **SP 3 · Medium**

### E3 · Privacy, compliance & security review — risks
**AC:** assess DNS-data sensitivity, retention limits, access control, encryption in transit,
and regulatory constraints for **both** options; sign-off from Security/Compliance. **SP 3 · High**

---

## EPIC F — Decision & Recommendation
*Goal: an evidence-based, signed-off decision.*

### F1 · Complete scorecard & weighted analysis — §2
**AC:** every scorecard cell filled from measured evidence; weighted totals computed for each
option; sensitivity noted (e.g. how SIEM-ingest cost or peak-QPS assumptions move the result). **SP 3 · High**

### F2 · Go/no-go recommendation & stakeholder sign-off — §8
**AC:** written recommendation per the decision framework, with evidence; presented to DDI +
Security + Ops; decision recorded; if dnstap, E2 becomes the rollout plan; if native, on-demand
logging guardrails are codified. **SP 3 · High**

---

## Summary

| Epic | Stories | Points |
|---|---|---|
| A — Environment & Baseline | A1–A3 | 7 |
| B — Performance | B1–B4 | 14 |
| C — Data Quality & Forensics | C1–C2 | 8 |
| D — Scale, Resilience & Storage | D1–D5 | 16 |
| E — Cost & Implementation | E1–E3 | 11 |
| F — Decision | F1–F2 | 6 |
| **Total** | **19 stories** | **62** |

**Suggested order:** A → B (baseline first, it gates everything) → C/D in parallel → E
(needs D3 volumes) → F (needs all evidence).
