# dnstap vs. Legacy DNS Query Logging — Evidence & Findings

**Question this answers:** *What concrete value does dnstap (the DNSTAP2 pipeline) add
or improve over NIOS native DNS query/response logging — and is it backed by evidence,
not vendor marketing?*

**How we get the evidence:** a **real single-server, sequential-mode test** — one NIOS member
replayed the **same query file** by `dnsperf`/`flamethrower` under each logging mode in turn
(baseline → native query logging → dnstap), recording the DNS-server-side cost (QPS ceiling,
latency, CPU, disk I/O) of each. Same box, same queries — only the logging mode changes. No
synthetic data on the server side.

**Status:** Test rig and method **defined below**; results tables are templates to fill from
the per-mode runs. A set of **preliminary lab measurements** of the *collector* side (storage,
compression, field fidelity, collector CPU/RAM) already exist (§6) and the test will
confirm/refine them with real, answer-bearing traffic. Nothing is asserted as a finding
without either a measurement or a cited primary source.

**Companion document:** [dnstap-collector-sizing.md](dnstap-collector-sizing.md) turns the
measured rates into a concrete VM build (CPU / RAM / disk / network).

---

## 1. Executive summary

DNS query telemetry is something we currently **cannot leave on**. NIOS native query/response
logging runs *inside* the DNS service path, and Infoblox's own documentation warns it
"can adversely affect DNS services and performance" and places "heavy compute demands on the
CPU and storage." So today it gets switched on to chase an incident and switched back off —
which means the data is usually **absent exactly when an investigation needs it.**

dnstap removes that trade-off by copying query *and* response events to a side channel
**asynchronously**, off the resolution hot path, and shipping them to a dedicated collector.
The decision for Marriott turns on two measurable questions:

1. **Does native logging actually cost DNS performance, and does dnstap avoid that cost?**
   → answered by the **single-server sequential test** in §4 (one NIOS member, same query file, dnsperf/flame).
2. **Is the dnstap pipeline cheap enough — and its data rich enough — to justify always-on?**
   → preliminary lab evidence already says yes (§6); the test confirms it with real traffic.

**The test, in one line:** take one NIOS member, replay the *identical* query file at increasing
load under each logging mode in turn, and compare where it breaks and what it captures in each mode.

| What the test measures | Expected to show | Confirmed by |
|---|---|---|
| Max sustainable QPS per mode | dnstap ≈ baseline; native logging lower | T2 |
| Latency (p50/p95/p99) under load | dnstap flat; native logging rises | T3 |
| DNS-server CPU & **disk I/O** | native logging higher (synchronous, on-box write) | T3 |
| Behaviour when the sink/disk is lost | dnstap: DNS unaffected; native: IO stall risk | T7 |
| Data captured per query | dnstap **60+ correlated fields** vs. one query-only line | T5 (§6 preview) |
| Storage footprint | dnstap larger raw, but ~55× compressible | T6 (§6 preview) |

**Bottom line (pre-test):** the collector is already shown to be cheap (~200 µs CPU/event,
~205 MB RAM) and rich (60+ correlated fields vs. a single query-only line), with its one real
cost — storage — collapsing ~55× under compression. The single-server test exists to **prove on
our own hardware** the remaining, decisive claim: that moving DNS logging off the resolution path
returns measurable performance headroom.

---

## 2. The two options, precisely

| | NIOS native query/response logging | dnstap → DNSTAP2 collector |
|---|---|---|
| **Where it runs** | Inside the DNS service process, on the member | Out-of-band side channel → separate collector host |
| **Sync/async** | Synchronous to the logging subsystem; writes to local disk | Asynchronous; never blocks resolution |
| **What's captured** | One syslog line per query (query-only by default) | Query **and** response event, fully correlated |
| **Transport** | syslog / local file (often rate-limited / truncated) | Frame Streams (fstrm) protobuf over TCP |
| **Always-on?** | Discouraged by vendor; toggled on-demand | Designed to be always-on |
| **Failure coupling** | Disk/IO pressure can stall the DNS service | Sink loss is absorbed off-path; DNS unaffected (T7) |

---

## 3. Methodology — single server, sequential modes

**Principle:** isolate one variable — the logging mode — and hold everything else constant
(**same hardware**, query file, load profile, network). Because it's one box tested in each mode
in turn, hardware variance is eliminated by construction; the variable to control instead is
**temporal** (cache state, drift, background load). Every reported number comes from a real run;
nothing on the DNS-server side is synthetic.

### 3.1 Test rig

```
                 same query file (identical bytes, checksummed)
        ┌──────────────────────────┐
        │  Load generator host      │   dnsperf / flamethrower
        └────────────┬─────────────┘   ramped QPS, repeated per mode
                     │ query stream
        ┌────────────▼─────────────┐
        │   ONE NIOS member         │   cycled through modes in sequence:
        │   (same box every run)    │   M0 baseline → M1 native → M2 native+resp → M3 dnstap
        └────────────┬─────────────┘
            dnstap (M3 only)│            native logging (M1/M2) → local disk
        ┌────────────▼─────────────┐
        │ DNSTAP2 collector         │   (only receives traffic during the dnstap run)
        │ 172.25.15.234 :6001       │
        └───────────────────────────┘
```

The server is a **NIOS grid member**; each mode is toggled on that one member from the **Grid
Manager GUI** (§3.6) between runs. Enabling dnstap is out-of-band and read-only — it does not
change resolution behaviour or answers.

### 3.2 Controlling for variance (critical — read before running)

A single-server sequential test removes hardware variance, but the runs happen at *different
times*, so guard against **temporal** drift:

1. **Identical everything except the mode** — same query file, generator, QPS profiles, warm-up,
   and zone data on every run. Pin the query file with a checksum so "same query file" is provable.
2. **Consistent warm-up before every measured run.** Each GUI mode change restarts DNS and cold-
   caches the member, so run a throwaway warm-up pass first; otherwise the first numbers reflect
   cache misses, not the logging mode.
3. **Run the modes in a fixed order, then re-measure baseline at the end** (M0 → M1 → M2 → M3 →
   M0'). If the closing baseline M0' matches the opening M0, no drift occurred and the deltas are
   trustworthy. If they differ, something temporal changed — investigate before trusting the run.
4. **Hold background conditions constant** — same time-of-day window if possible, no competing
   load on the member or generator, quiet network. Note anything you can't control.
5. **Repeat each mode ≥3×; report medians.** Treat the cold-cache first pass as a separate
   data point, not part of the median.
6. **Neutralize the cold cache** — every GUI mode switch restarts DNS and flushes the resolver
   cache; control this per §3.7 so cache state is identical at the start of every measured run.

### 3.3 Load generation

- **Tool:** `dnsperf` *or* `flamethrower` (flame). Either is fine; keep ONE tool across all runs.
  - `dnsperf -d <queryfile> -s <server> -Q <qps>` (or `-c`/`-T` for concurrency) — reports
    achieved QPS, latency, loss, rcode breakdown.
  - `flame <server> -q <queryfile> -Q <qps> -c <concurrency>` — modern, supports TCP/DoT/DoH if
    needed; same idea.
- **Query file:** the *same file* for every run. Prefer one derived from a **real production
  capture** (representative qname/qtype mix, cache-hit vs. miss ratio, NXDOMAIN share) so the
  result reflects Marriott traffic. Record its size and query count.
- **Load profiles** (define once, reuse): **P1 steady** (e.g. expected production QPS),
  **P2 peak** (ramp to near-saturation), **P3 burst** (spikes), **P4 soak** (P1 for 2–4 h).

### 3.4 Logging-mode sequence (one server, one mode at a time)

Infoblox warns specifically against running query **and** response logging together. Run these
modes in order on the single member, recording the same metrics each time:

| Run | Mode on the member | Purpose |
|---|---|---|
| M0 | all logging **off** | the reference everything is measured against |
| M1 | native **query logging only** | the "normal" legacy logging penalty |
| M2 | native **queries + responses** | the stress case Infoblox warns against |
| M3 | **dnstap** (client queries+responses; +resolver if recursive) | the proposed always-on path |
| M0' | all logging **off** again | drift check — should reproduce M0 |

> Only one mode is enabled at a time; disable the previous mode before enabling the next so each
> run measures exactly one logging path.

### 3.5 Instrumentation (capture on every run)

- **From the generator:** achieved QPS, latency p50/p95/p99/max, queries lost/timed-out, rcode
  distribution.
- **On the DNS member:** CPU % and memory via NIOS SNMP (`IB-PLATFORMONE-MIB` / `ibSystemMonitor`
  — `ibSystemMonitorCpuUsage` `1.3.6.1.4.1.7779.3.1.1.2.1.8.1.1.0`, `ibSystemMonitorMemUsage`
  `…8.2.1.0`; the harness polls these automatically when `SNMP_COMMUNITY` is set). NIOS exposes
  CPU/mem via its enterprise MIB, not HOST-RESOURCES/UCD, and does **not** surface fine-grained
  disk I/O over SNMP — for the native-logging **disk-write** cost, read the member's logging/disk
  stats from the GUI (or infer it from the log-volume growth) rather than from SNMP.
- **On the collector:** events/s ingested, drops, CPU/RAM, bytes written (for T6/§6).
- Export every run to a results sheet keyed by `(test, mode, profile, run#)`.

### 3.6 Switching modes on the member (Grid Manager GUI)

All modes are toggled on the one member from the GUI — no WAPI/script needed for this test. (The
repo's [infoblox-ops-playbook.md](infoblox-ops-playbook.md) Path A covers the dnstap GUI steps in
full.) **Each change triggers a DNS-service restart** — schedule a short change window per switch,
disable the previous mode first, and re-warm the cache before measuring.

**M1/M2 — native query logging (Data Management → DNS → Members → member → Edit → Logging):**
- Enable **query logging** (M1). For **M2**, additionally enable **response logging** — the
  combination Infoblox advises against, which is exactly what M2 measures.
- **Save** → restart DNS if prompted. For M3, turn this **back off** first.

**M3 — dnstap (member → Edit → near Logging):**
- Tick **Override** so the member uses its own dnstap setting (`use_dnstap_setting`).
- **Enable dnstap** ✔; **dnstap receiver address** = `172.25.15.234`; **port** = `6001`.
- **Send client queries** ✔ and **Send client responses** ✔ (add **resolver queries/responses**
  for recursive visibility). Native logging **OFF**.
- **Save** → restart DNS if prompted. Verify events with `identity = <member FQDN>` arrive
  (ops-playbook §4) before starting load.

> Field labels vary by NIOS build — map by meaning (receiver address/port, enable queries/
> responses). Confirm on the POC grid's build (NIOS 9.x exposes `dnstap_setting`,
> `enable_dnstap_queries/responses`, `use_dnstap_setting`).

### 3.7 Cache-state control (avoiding the cold-cache confound)

Every GUI mode switch (§3.6) restarts the member's DNS service and **flushes the resolver
cache**. If load starts immediately, the first queries are cache misses driving recursion to
upstream — so the early numbers reflect *upstream RTT*, not the logging mode under test. How you
handle this depends on the member's role; pick one and apply it **identically to every mode**.

**Preferred — test authoritatively (the cold-cache problem disappears).**
Point the query file at zones the member is **authoritative** for (build a test zone covering the
names in the file, or reuse zones it already serves). Every answer comes from local zone data —
no resolver cache, no upstream, no warm-up. A DNS restart just reloads zones, so runs are
reproducible across mode switches. This also *isolates the cost you care about* — "serve one
query + log it" — because logging overhead is per-query regardless of cache hit/miss, with no
upstream-RTT noise swamping the signal. This is the recommended default unless the recursive path
is specifically what you need to characterize.

**If you must test the recursive resolver path** — you can't avoid the flush, so make cache state
identical at the start of every measured run (it then cancels in the M0→M3 deltas):
1. **Settle after restart** — wait a fixed interval (or until QPS/latency stabilize) before doing
   anything; the OS page cache is cold too.
2. **Deterministic warm-up** — replay the full unique query set once (or `dnsperf -l 60` as a
   throwaway) and discard it. Same warm budget for every mode.
3. **Measure steady-state only** — run long (e.g. `-l 300`) and analyze only the stable window;
   drop the first 30–60 s.
4. **Cache-friendly, pinned query file** — a fixed name set with repetition so the post-warm hit
   ratio is ~constant across modes; checksum the file so it's provably identical.
5. **Verify warmth** — confirm the member's cache hit ratio (NIOS stats) is at steady-state before
   the measured pass.

**Interpretation aid (either path):** **CPU and disk I/O are cache-independent** — logging cost is
paid per event regardless of hit/miss — so those metrics are robust to cold cache. It is mainly
**latency and the QPS ceiling** that the warm-up protects. Whichever path you choose, the proof
that cache state was consistent is the **closing-baseline drift check (M0' ≈ M0)** from §3.2.

---

## 4. Test plan & results template

Fill these from the per-mode runs. Leave the "result" cells until measured — do not pre-fill.
The interactive harness in [`scripts/poc/`](../scripts/poc/README.md) runs these tests
(`run_test_dnstap.sh`, `run_test_querylog.sh`) and `process_results.py` emits the filled tables.

### T1 — Baseline & drift check (M0 at start, M0' at end)
| Run | QPS ceiling | p95 latency | CPU % | Δ M0'–M0 (must be small) |
|---|---|---|---|---|
| M0 (start) | _____ | _____ | _____ | — |
| M0' (end) | _____ | _____ | _____ | _____ |

### T2 — Max sustainable QPS per mode  *(ramp until p95 latency or loss breaks SLA)*
| Mode | Max QPS | vs. baseline |
|---|---|---|
| M0 baseline | _____ | — |
| M1 native queries-only | _____ | ___% |
| M2 native queries+responses | _____ | ___% |
| M3 dnstap | _____ | ___% |

### T3 — Latency / CPU / disk I/O at fixed load (P1 steady & P2 peak)
| Mode | p50 | p95 | p99 | CPU % | Disk write MB/s | IO await |
|---|---|---|---|---|---|---|
| M0 baseline | | | | | | |
| M1 native queries-only | | | | | | |
| M2 native queries+responses | | | | | | |
| M3 dnstap | | | | | | |

### T4 — Soak (P1, 2–4 h, per mode)
Watch for CPU creep, memory growth, latency drift, log/disk fill, collector keep-up. Pass = stable.

### T5 — Data completeness (per query, both paths) — *preview in §6*
For a sample of N queries: which fields does each path capture? dnstap = query+response
correlated, recursion (RESOLVER_*), timing, 5-tuple, EDNS, RPZ. Native = ? Gap analysis.

### T6 — Storage volume & growth per mode — *preview in §6*
| Mode | bytes/event (raw) | GB/day @ P1 | GB/day compressed | retention cost (30/90/365 d) |
|---|---|---|---|---|

### T7 — Failure modes (the safety test)
- **dnstap:** kill the collector / drop the network mid-load → **does DNS latency/availability
  stay flat?** Characterize buffer/drop behaviour. *Pass = DNS unaffected.*
- **native:** fill the log disk / stall IO mid-load → what happens to resolution?

---

## 5. Decision framework (go / no-go)

Recommend **dnstap** if T2/T3 show it has **materially lower DNS performance impact** than
native logging at peak, T7 shows DNS stays healthy when the sink is lost, T5 confirms the data
completeness advantage, and the storage/SIEM cost (T6 + sizing doc) is acceptable. Recommend
**staying on native logging** only if its measured penalty is negligible at our real peak
**and** dnstap's storage/SIEM cost is disproportionate — in which case codify strict on-demand
logging. A tie breaks toward whichever better protects **DNS availability**, the primary mandate.

---

## 6. Preliminary lab measurements (collector side)

These were measured on the DNSTAP2 lab stack (DNS-collector v2.2.3) by streaming dnstap into
the collector. They characterize the **dnstap format and the collector** — independent of which
DNS server produces the stream — so they are valid as *expectations* and as inputs to sizing.
**The single-server test will confirm/refine them with real, answer-bearing responses** (note: the lab
sample had mostly empty answer sections, so real bytes/event will likely run *somewhat higher*).

| Property | Lab measurement | Refined by |
|---|---|---|
| Collector CPU | ~**200 µs/event** → 1 core ≈ 5,000 events/s | T2/T6 with real traffic |
| Collector RAM | ~52 MB idle → plateaus ~**205 MB** under load | T4 soak |
| Storage, raw JSON | **1,745 B/event** (empty-answer sample — expect higher with real answers) | T6 |
| Storage, gzip | **31.9 B/event = 54.7×** | T6 |
| Field fidelity | **60+ fields/event** (see below) | T5 |
| Footprint | single 40 MB static Go binary | — |

**Field fidelity captured by dnstap (the qualitative win):**

```
dns.qname, dns.qtype, dns.qclass, dns.rcode, dns.id, dns.length, dns.qd/an/ns/arcount
dns.flags.qr/aa/tc/rd/ra/ad/cd            (every header flag)
dns.resource-records.an/ns/ar.*           (full answer/authority/additional sections)
dnstap.operation = CLIENT_QUERY|CLIENT_RESPONSE|RESOLVER_QUERY|RESOLVER_RESPONSE
dnstap.timestamp-rfc3339ns, dnstap.latency_ms     (nanosecond timing; query↔response latency)
dnstap.policy-action/match/type/value     (RPZ / response-policy visibility)
network.query-ip/port, network.response-ip/port, network.family, network.protocol  (5-tuple)
edns.udp-size, edns.dnssec-ok, edns.options.*     (EDNS / DNSSEC)
```

Native NIOS query logging is, by contrast, a single query-only syslog line (e.g.
`client 10.1.1.1#54321: query: example.com IN A`) — no response, no rcode correlation, no
timing, no recursion view, subject to syslog rate-limiting/truncation. This is the largest
qualitative gap and is what enables the SIEM/forensic use cases (DNS tunneling via TXT/NULL/ANY
volume, NXDOMAIN/DGA spikes, per-client domain history) that query-only logs can't answer.

---

## 7. Caveats & limitations

- **Temporal drift is the key risk** (the flip side of using one box): runs happen at different
  times, so cache state, background load, or time-of-day can masquerade as a mode difference.
  §3.2 neutralizes this with consistent warm-up, fixed run order, and the **closing-baseline
  drift check (M0')** — if M0' ≠ M0, do not trust the deltas until you find what changed.
- **Query file representativeness.** Results are only as production-like as the query file.
  Use a real capture; record its qtype mix and cache hit/miss ratio.
- **Generator must not be the bottleneck.** Run the load generator on a separate, well-resourced
  host; confirm it can offer more QPS than the server can serve (otherwise you measure the
  generator, not the server).
- **Recursion vs. authoritative.** A recursive resolver's numbers differ from an authoritative
  server's; test the role you actually run, and handle the cold-cache confound per §3.7
  (authoritative removes it entirely; recursive needs consistent warm-up).
- **bytes/event will rise with real answers.** The §6 figure came from largely empty-answer
  synthetic responses; real A/AAAA/TXT answers add bytes — re-measure in T6.
- **Compression is offline (gzip at rest).** Size **SIEM ingest licensing on the raw number**,
  **local storage on the compressed number**.
- **events ≠ queries.** One query = ≥2 dnstap events (CLIENT_QUERY+RESPONSE), up to 4 with a
  recursive miss. Apply the multiplier to QPS for all sizing.
- **Privacy/compliance.** Full DNS telemetry is sensitive — retention limits, access control,
  and encryption in transit apply to either option.

---

### Sources
- Infoblox — DNS Query Logging performance/disk caveats: <https://docs.infoblox.com/space/nios90/1580827644>
- Infoblox community — logging performance impact: <https://community.infoblox.com/t5/nios-dns-dhcp-ipam/infoblox-logging-performance-impact/td-p/25121>
- Infoblox — Configuring dnstap: <https://docs.infoblox.com/space/nios90/1432748211>
- dnstap — high-speed DNS logging without packet capture: <https://dnstap.info/slides/dnstap_nanog60.pdf>
- NXLog — syslog vs dnstap (completeness/fidelity): <https://nxlog.co/news-and-blog/posts/monitoring-bind9-logs-syslog-vs-dnstap>
- dnsperf: <https://github.com/DNSPerf/dnsperf> · flamethrower: <https://github.com/DNS-OARC/flamethrower>

*Preliminary collector figures in §6 are from the DNSTAP2 lab stack (DNS-collector v2.2.3,
2026-06-08). DNS-server-side findings (§4) are filled from the single-server sequential test on real
hardware.*
