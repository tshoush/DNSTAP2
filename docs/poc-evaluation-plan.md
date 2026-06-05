# POC Evaluation Plan — DNS Query Logging vs. dnstap

**Decision to make:** Should we keep using **NIOS native DNS query/response logging**,
or move to **dnstap** (the DNSTAP2 pipeline) for always-on DNS query telemetry?

**How we decide:** run a structured set of technical tests in the lab, quantify the
trade-offs (performance, data quality, resilience, storage, cost, operations), score
each option against weighted criteria, and produce a go/no-go recommendation with
evidence.

This document is the **plan**. It defines the tests, the cost and implementation
analysis we must complete, the risks to address, and the decision framework. The
matching execution backlog is in [jira-stories.md](jira-stories.md).

---

## 1. Why this decision matters (background)

Native query logging on NIOS runs **inside** the DNS service path. Infoblox's own
guidance is blunt: enabling query and response logging together "can increase disk
space usage and adversely affect DNS services and performance," and they recommend not
running both at once; the work of logging/formatting places "heavy compute demands on
the CPU and storage," which "can overload server resources… degrading DNS core and
hosted service availability." That is exactly why teams turn it on only to chase a
problem and turn it back off — so the data is usually missing when an incident occurs.

dnstap is Infoblox's (and the wider DNS community's) recommended alternative: it copies
query/response events to a side channel **asynchronously**, "without significant
performance tradeoff," and preserves the **full** query *and* response bundled together
in binary form — ideal for SIEM, forensics, and threat hunting. The trade-off is a
**larger storage footprint** and a **new pipeline to operate** (collector, metrics, log
store). The POC must quantify both sides so the choice is evidence-based, not anecdotal.
*(Sources at the end.)*

---

## 2. Decision criteria & scorecard

Each option is scored 1–5 per criterion; weights reflect business priority. The POC's
job is to fill in the evidence for each cell.

| # | Criterion | Weight | What "good" looks like |
|---|---|---|---|
| C1 | **DNS performance impact** (QPS ceiling, latency, CPU) | 25% | Minimal/no measurable degradation under peak load |
| C2 | **Data completeness & fidelity** | 20% | Query+response correlated, recursion visible, full fields |
| C3 | **Resilience / "always-on" safety** | 15% | Telemetry never threatens DNS availability; survives sink loss |
| C4 | **Scale** (grid-wide, sustained) | 10% | Stable over hours at production QPS |
| C5 | **Storage & retention cost** | 10% | Predictable, affordable volume for required retention |
| C6 | **Security / forensics value** | 10% | Strong SIEM/threat-hunt/tunneling-detection support |
| C7 | **Operational cost & complexity** | 10% | Sustainable day-2 ops, clear runbooks, HA |

> Fill the scorecard from measured results (§3–§5). The weighted total per option drives
> the recommendation in §8.

---

## 3. Technical test plan

**Lab & method.** Use a non-production NIOS member (lab/POC grid) plus the DNSTAP2
collector stack already deployed. Drive load with **dnsperf**/**dnstrace** against the
member from a separate generator host so the generator isn't competing for the member's
CPU. Repeat each run ≥3× and report medians; hold dataset, query mix, and hardware
constant across conditions so only the logging mode varies.

**Load profiles** (define once, reuse): P1 steady (e.g. 5k QPS), P2 peak (the member's
near-saturation QPS from T1), P3 bursty (spikes), P4 soak (P1 for 2–4 h). Query mix
should include cache hits, cache misses (recursion), NXDOMAIN, and a realistic
qtype/qname distribution.

| ID | Test | Method | Metrics / Pass criteria |
|---|---|---|---|
| **T1** | **Baseline** (no logging) | dnsperf at increasing QPS until latency/SLA breaks | Max sustainable QPS; p50/p95/p99 latency; member CPU/mem/IO. Establishes the reference. |
| **T2** | **Native query logging** | Enable NIOS query logging (queries only; then responses; then both) | Re-run T1 profiles; record **% QPS drop**, latency delta, CPU/IO delta vs baseline, for each logging mode |
| **T3** | **dnstap** | Enable dnstap → collector; disable native logging | Re-run T1 profiles; record QPS/latency/CPU delta vs baseline |
| **T4** | **Head-to-head delta** | Compare T2 vs T3 against T1 | Quantified performance penalty of each option at P2 peak; which preserves more DNS headroom |
| **T5** | **Data completeness/fidelity** | Sample N queries through each path; inspect output | dnstap: query+response correlated, recursion (RESOLVER_*) present, client IP/qname/qtype/rcode/timing complete. Native: what fields are captured, is response correlated? Gap analysis |
| **T6** | **Soak / sustained scale** | P4 (2–4 h) under each mode | No CPU creep, memory leak, or latency drift over time; collector keeps up; zero member instability |
| **T7** | **Failure modes & backpressure** | Kill the collector / drop the network mid-stream under load | **Does DNS resolution stay healthy?** Measure DNS latency/availability during sink loss. Characterize dnstap buffer/drop behavior. (Native logging: behavior when disk fills / IO stalls) |
| **T8** | **Storage volume & growth** | Measure bytes/event and rate at P1/P2 for each | GB/day at production QPS; project storage for required retention (e.g. 30/90/365 d); compression ratio |
| **T9** | **Pipeline throughput** (dnstap only) | Drive collector at increasing event rates | Collector max events/s before drop; Prometheus/Loki ingest headroom; Grafana responsiveness; resource use of the telemetry host |
| **T10** | **Security/forensics value** | Run representative SIEM/threat-hunt queries on each dataset | dnstap → Splunk/Loki: can we do DNS-tunneling detection (TXT/NULL/ANY volume), NXDOMAIN/DGA spikes, per-client domain history? Native: same questions, what's answerable? |
| **T11** | **Interface & network** | Validate egress interface options | dnstap over LAN1 vs MGMT (out-of-band); firewall rule `DNS→collector:6001`; confirm no data-plane coupling |

**Instrumentation.** Capture member CPU/mem/IO during every run (node_exporter or NIOS
SNMP `ibPlatformOne`); capture collector/Prometheus/Loki resource use; export all raw
results to a results sheet keyed by (test, mode, profile, run#).

---

## 4. Cost analysis (to complete during the POC)

The recommendation must include a **3-year TCO** comparison, not just per-unit prices.
Build it from these line items and the measured volumes from §3.

**Native query logging — costs.** The dominant cost is **consumed DDI performance
headroom**: every logged query competes with resolution for CPU/IO (quantified in T2),
which can force **earlier hardware/appliance upgrades** or additional grid members to
restore headroom — a real capital cost even though logging itself is "free" in licensing.
Add: storage/reporting burden on the grid (and any Infoblox Reporting/Analytics or **Data
Connector VM** licensing if used to offload it), plus the operational reality that the
data often isn't on when needed (an **incident-response cost** — slower investigations,
missed forensics).

**dnstap (DNSTAP2) — costs.** New but bounded: the **collector host(s)** (small native
binaries; possibly HA pair), **storage** for Prometheus + Loki (and any **Splunk/SIEM
ingest licensing**, which is volume-based — size it from T8's GB/day), and **day-2
operational effort** for the pipeline. No additional NIOS feature license for dnstap
itself. Because the load is moved off the DNS members, it **preserves DDI headroom**,
potentially **deferring appliance upgrades** — a cost *avoidance* that should be credited
to dnstap in the TCO.

**Net comparison.** Tabulate: appliance/headroom impact, per-feature licensing, storage
($/GB × retention × GB/day), SIEM ingest, and FTE/ops effort, over 3 years, for both
options. The decision often turns on **SIEM ingest volume** (dnstap can be high) vs.
**DDI capacity erosion** (native logging's hidden tax). Both must be quantified, not
assumed.

---

## 5. Implementation & operational analysis (to complete)

If dnstap is chosen, the rollout is already de-risked by existing assets and must be
documented as the implementation plan: phased per-member enablement via the
[InfoBlox Ops playbook](infoblox-ops-playbook.md) (dry-run → snapshot → apply), starting
with one low-risk member and widening by site/role. Day-2 operations need: **collector
HA / sizing** (from T9), **retention policy** and storage lifecycle (from T8), **SIEM
integration** (Splunk HEC / syslog), **alerting** (Alertmanager rules already shipped:
receiver-down, silent-stream, NXDOMAIN/SERVFAIL spikes, tunneling heuristic), **dashboards**
(the 14-panel Grafana board), and **monitoring of the telemetry host itself** (see
[SNMP-Integration.md](SNMP-Integration.md)). Change management is low-risk because dnstap
is additive and reversible (snapshot rollback), but a **member DNS-service restart may be
required** to apply the setting — schedule per member. If native logging is kept instead,
the implementation work is the opposite: define strict **on-demand** logging procedures,
guardrails to prevent leaving it on, and capacity buffers to absorb the load when it is on.

---

## 6. Risks & issues to address

- **Performance regression** (native): logging under peak load degrading resolution —
  the core risk the POC must measure (T2/T4), not assume.
- **Backpressure / data loss** (dnstap): if the collector or network is lost, does DNS
  stay healthy, and what happens to in-flight events? Must be characterized (T7); the
  telemetry path must **never** block resolution.
- **Storage growth** (both, worse for dnstap): unbounded volume at scale — size and cap
  with retention; risk of SIEM ingest cost overrun (T8).
- **Single point of failure** (dnstap): the collector — needs HA or graceful degradation.
- **Privacy / compliance:** DNS query data is sensitive (reveals user/host behavior).
  Address retention limits, access control, encryption in transit (SNMPv3/TLS where
  applicable), and any regulatory constraints — for **both** options.
- **Security of the telemetry channel:** restrict `:6001` to DNS members; prefer the
  out-of-band/MGMT path; protect the collector and stores.
- **NIOS build variance:** dnstap field names differ across builds (handled by schema
  discovery in the config script) — validate on the target build.
- **Scale tail:** behavior at the top of the grid's QPS, and grid-wide fan-in to one
  collector — the long tail T9 must cover.
- **Lab-vs-prod fidelity:** ensure the POC's hardware/QPS approximate production, or
  scale results with stated assumptions.

---

## 7. Deliverables

1. Completed **scorecard** (§2) with measured evidence per cell.
2. **Performance report** (T1–T4, T6, T7) with charts: QPS ceiling and latency/CPU
   deltas, baseline vs native vs dnstap.
3. **Data-quality / forensics findings** (T5, T10).
4. **Storage & TCO model** (T8, §4) — 3-year, both options.
5. **Implementation plan** (§5) for the chosen option.
6. **Go/no-go recommendation** (§8) signed off by DDI + Security + Ops.

---

## 8. Decision framework (go / no-go)

Recommend **dnstap** if: it shows **materially lower DNS performance impact** than native
logging at peak (T4), keeps DNS healthy under sink failure (T7), meets data-completeness
needs (T5/T10), and its 3-year TCO (including SIEM ingest) is acceptable versus the DDI
headroom that native logging consumes. Recommend **staying on native logging** only if the
measured performance penalty is negligible at our real peak **and** the storage/SIEM cost
of dnstap is disproportionate to the forensic value — in which case codify strict on-demand
logging procedures. A weighted-scorecard tie breaks toward the option that better protects
**DNS availability** (C1+C3), the primary mandate.

---

### Sources
- Infoblox — DNS Query Logging (performance/disk caveats; don't enable both): <https://docs.infoblox.com/space/nios90/1580827644>
- Infoblox community — logging performance impact: <https://community.infoblox.com/t5/nios-dns-dhcp-ipam/infoblox-logging-performance-impact/td-p/25121>
- Infoblox — Configuring dnstap to log DNS queries/responses: <https://docs.infoblox.com/space/nios90/1432748211/Configuring+dnstap+to+Log+DNS+Queries+and+Responses>
- dnstap — high-speed DNS logging without packet capture (overhead scales well): <https://dnstap.info/slides/dnstap_nanog60.pdf>
- NXLog — syslog vs dnstap for DNS visibility (completeness/fidelity): <https://nxlog.co/news-and-blog/posts/monitoring-bind9-logs-syslog-vs-dnstap>
- DN.org — scalable DNS logging with dnstap (storage/scale): <https://dn.org/scalable-dns-logging-with-dnstap/>
- dnsperf — DNS performance testing tool: <https://github.com/DNSPerf/dnsperf>
