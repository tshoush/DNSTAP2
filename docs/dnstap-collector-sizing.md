# DNSTAP2 Collector — VM Sizing

**Purpose:** specify the virtual machine(s) to build for the dnstap collector, with CPU,
RAM, disk, and network sized from **measured** rates — not guesses.

**Inputs:** all figures derive from the preliminary collector measurements in
[dnstap-value-evidence.md](dnstap-value-evidence.md) §6 (DNSTAP2 lab stack, DNS-collector
v2.2.3). These will be **confirmed/refined by the single-server sequential test** (T6) on real
traffic — in particular `bytes/event` will run *higher* than the lab figure because the lab
sample had mostly empty answer sections, whereas real A/AAAA/TXT responses carry answer records.
**Treat the storage tables below as a lower-bound estimate and re-run them with the measured
`bytes/event` from the dnstap run.**
The collector runs the full local stack: DNS-collector receiver + Prometheus + Loki + Grafana +
Alertmanager (per `scripts/install_stack.sh`).

---

## 1. Measured unit costs (the basis for everything below)

| Resource | Lab value (preliminary) | Confirmed by test |
|---|---|---|
| CPU per event | **~200 µs CPU** (one core ≈ 5,000 events/s) | T2/T6 real traffic |
| Memory (receiver) | ~52 MB idle → **~205 MB** under load | T4 soak |
| Storage, raw JSON | **1,745 bytes/event** *(empty-answer sample — expect higher)* | T6 |
| Storage, gzip | **31.9 bytes/event (54.7×)** | T6 |
| Binary footprint | 40 MB static Go binary | — |

> **WSL2 conservatism:** the CPU figure was taken under WSL2 on a laptop CPU. Bare-metal/
> hypervisor RHEL will do *at least* as well, so sizing on ~5,000 ev/s/core leaves headroom.

---

## 2. Translate your QPS into events/s (do this first)

dnstap emits **multiple events per user query**:

- CLIENT_QUERY + CLIENT_RESPONSE = **2 events** per query (baseline, response logging on)
- on a recursive cache miss, add RESOLVER_QUERY + RESOLVER_RESPONSE = **up to 4 events**

**Rule of thumb:** `events/s ≈ QPS × 2` (authoritative / high cache-hit), up to `× 3–4` for
recursion-heavy resolvers. Size on the upper bound for safety.

> Example: a member doing **5,000 QPS** with moderate recursion → plan for **~12,000–
> 15,000 events/s**. Grid-wide fan-in multiplies this across all members feeding one collector.

---

## 3. CPU & RAM sizing

### Receiver CPU, by sustained event rate (@ ~200 µs/event measured)

| Events/s | Cores for receiver | + stack overhead (Prom/Loki/Grafana) | **Recommended vCPU** |
|---|---|---|---|
| ≤ 5,000 | ~1.0 | +1–2 | **4** |
| 10,000 | ~2.0 | +2 | **4–6** |
| 20,000 | ~4.0 | +2–3 | **8** |
| 50,000 | ~10.0 | +3–4 | **16** |

Prometheus + Loki + Grafana + Alertmanager add a roughly fixed 1–3 cores depending on query/
dashboard load and Loki ingestion; the table already folds that in.

### RAM

Receiver itself is ~205 MB under load. The memory budget is dominated by **Loki** (log
ingestion/indexing) and **Prometheus** (TSDB + query), not the receiver.

| Deployment | **Recommended RAM** | Notes |
|---|---|---|
| Single-member POC / ≤5k ev/s | **8 GB** | comfortable for full stack |
| Grid subset / ≤20k ev/s | **16 GB** | Loki + Prometheus headroom |
| Grid-wide / ≥50k ev/s | **32 GB** | consider splitting stores (§6) |

---

## 4. Disk sizing — the dimension that actually drives the build

Storage, not CPU, is the binding constraint. Size on the **compressed** rate (54.7×); keep a
small **raw staging** buffer for the un-rotated/un-compressed tail.

### Compressed storage by event rate and retention

| Events/s | gz/day | **30-day** | **90-day** | **365-day** |
|---|---|---|---|---|
| 500 | 1.4 GB | 41 GB | 124 GB | 0.50 TB |
| 1,000 | 2.8 GB | 83 GB | 248 GB | 1.0 TB |
| 2,500 | 6.9 GB | 207 GB | 620 GB | 2.5 TB |
| 5,000 | 13.8 GB | 413 GB | 1.24 TB | 5.0 TB |
| 10,000 | 27.6 GB | 827 GB | 2.48 TB | 10.1 TB |
| 20,000 | 55.1 GB | 1.65 TB | 4.96 TB | 20.1 TB |
| 50,000 | 137.8 GB | 4.13 TB | 12.4 TB | 50.3 TB |

> Raw (uncompressed) is ~**55× larger** — e.g. 5,000 ev/s = **754 GB/day raw**. Only a rolling
> staging window (hours, not days) is ever stored raw; everything at rest is compressed.

### Recommended disk layout

| Mount | Size | Purpose |
|---|---|---|
| `/` (OS + binaries) | **40–60 GB** | RHEL + 40 MB collector + stack binaries |
| `/var/log/dnscollector` (raw staging) | **50–100 GB** | un-rotated JSONL tail before compression/ship |
| `/var/lib` (Prometheus TSDB + Loki chunks) | **from table above + 30% headroom** | the retention store; thin-provision / expandable LVM |

**Build the data volume as expandable LVM** so retention can grow without rebuilding the VM.
If a SIEM (Splunk) is the system of record, local Loki retention can be short (7–14 days
hot) and the table shrinks dramatically.

---

## 5. Network sizing

dnstap on the wire is compact protobuf (smaller than the 1,745 B JSON-at-rest figure). Even so,
ingress is modest:

| Events/s | Approx. ingress (protobuf, ~order of) | Verdict |
|---|---|---|
| 5,000 | a few Mbps | 1 GbE is ample |
| 50,000 | tens of Mbps | 1 GbE is ample; 10 GbE only for very large grids |

- **NIC:** 1 × **1 GbE** for POC and most production; **10 GbE** only at the very top of grid-
  wide fan-in or if SIEM egress is co-located.
- **Out-of-band path:** prefer the MGMT interface for the `:6001` dnstap stream so telemetry
  never shares the DNS data plane (per the evaluation plan's T11).
- **Firewall:** allow only DNS members → collector `:6001`. (See [firewall-ports.md](firewall-ports.md).)

---

## 6. Recommended builds

### A. POC / single-member (current `infoblox-poc-01` profile)
Matches the live POC. Validates the pipeline end-to-end before scaling.

| Resource | Spec |
|---|---|
| vCPU | **4** |
| RAM | **8 GB** |
| Disk | 50 GB OS + **200 GB** expandable data (≈90-day @ ≤2.5k ev/s) |
| NIC | 1 GbE (MGMT for dnstap ingest) |
| OS | RHEL 7.9+ (musl Vector path handled by installers if Vector is ever used) |

### B. Production, single collector (grid subset, ≤20k ev/s)

| Resource | Spec |
|---|---|
| vCPU | **8** |
| RAM | **16 GB** |
| Disk | 60 GB OS + 100 GB raw staging + **2 TB** expandable data (≈90-day @ ~10k ev/s) |
| NIC | 1 GbE (10 GbE optional) |

### C. Grid-wide / HA (≥50k ev/s, no single point of failure)

dnstap's one architectural risk is the collector being a SPOF. At grid scale:

- **2× collector VMs** (active/active or active/standby), members split or dual-homed across
  them — instant fallback, and the side-channel design means a collector outage never touches
  DNS resolution.
- Consider **splitting roles**: receiver+Loki on the collector VMs; Prometheus+Grafana on a
  separate smaller "observability" VM so dashboard/query load doesn't compete with ingest.

| Per collector VM | Spec |
|---|---|
| vCPU | **16** |
| RAM | **32 GB** |
| Disk | 60 GB OS + 100 GB raw staging + **expandable multi-TB** data (size from §4 at real rate) |
| NIC | 10 GbE, MGMT-segregated ingest |

---

## 7. Sizing checklist before you build

1. **Get real QPS** per member (and the recursion mix) from NIOS — do not guess. Convert to
   events/s with the §2 multiplier.
2. **Decide retention** and **system of record** (local Loki vs. Splunk). This is the single
   biggest lever on disk size — short local + long SIEM shrinks the data volume sharply.
3. **Pick a build (§6)** from the resulting events/s, and **provision the data volume as
   expandable LVM** so retention can grow.
4. **Confirm CPU/event and bytes/event from the dnstap run** (T6) — the real dnstap stream from a
   live DNS server under dnsperf/flame is the authoritative source; the lab figures are a
   conservative starting point (CPU was generator-bound; bytes/event will rise with real answers).
5. **Size SIEM ingest licensing on the RAW number** (~1,745 B/event, refine from T6), local
   storage on the **compressed** number (~31.9 B/event).

*All projections computed from measured unit costs in
[dnstap-value-evidence.md](dnstap-value-evidence.md) (DNS-collector v2.2.3, 2026-06-08).*
