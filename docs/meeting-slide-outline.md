# Slide Outline — dnstap vs. Data Connector→HEC Decision

12 slides, ~20 min. Speaker notes under each. Mirrors `poc-business-case.html` style.

---

### Slide 1 — Title
**DNS Telemetry to Splunk: dnstap vs. Data Connector → HEC**
*The decision is the source, not the transport.*
- Presenter, date, "Decision meeting"

### Slide 2 — The question on the table
- Option A: dnstap → Vector → Splunk HEC
- Option B: NIOS DNS logging → Infoblox Data Connector → Splunk HEC
- "Both end at HEC. So what are we actually choosing?"
- *Note: plant the reframe early.*

### Slide 3 — Why we're here (the status quo pain)
- Native DNS query logging degrades DNS performance → we turn it OFF
- Result: "data is absent exactly when an investigation needs it"
- Infoblox's own docs: "can adversely affect DNS services and performance," "heavy compute demands on CPU and storage"
- *Cite: dnstap-value-evidence.md:24-30*

### Slide 4 — The reframe (the money slide)
- 2×2 matrix: Source axis (in-path logging vs dnstap) × Transport axis (scp vs HEC)
- Option B = new transport, **same in-path source**
- Option A = new source, **also HEC transport**
- "scp→HEC is a transport upgrade. dnstap is a source upgrade. Different problems."

### Slide 5 — What HEC fixes (and what it doesn't)
- Fixes: latency, reliability, indexer distribution, metadata control
- Does NOT fix: DNS member CPU/IO, data completeness, Splunk GB/day
- *Be fair to B here — concede the transport win fully.*

### Slide 6 — What dnstap fixes
- Out-of-band → always-on (no toggle)
- Query+response correlation, 60+ fields (rcode, latency, RPZ, 5-tuple, EDNS/DNSSEC)
- vs native: single query-only line, no response/rcode/timing
- Failure isolation: collector dies, DNS keeps serving
- *Cite: dnstap-value-evidence.md:301-318; ARCHITECTURE.md:160-169*

### Slide 7 — Scenario: 2am forensics (lead scenario)
- B: pre-alert window empty (logging was off); query-only even when on
- A: 30/90 days already in Splunk with full response correlation → answered in minutes
- *This is the emotional win. Spend time here.*

### Slide 8 — Scenario: peak load
- B: logging competes with resolution at peak → QPS drop / latency; disk-full risk
- A: async side-channel; overload drops events, never queries
- *Cite: poc-evaluation-plan.md T2/T4/T7*

### Slide 9 — The honest costs of dnstap
- More events: events/s ≈ QPS×2 (up to ×4) → higher Splunk license
- Storage table: 5k eps → 413 GB/30d compressed (raw ~55×)
- No collector HA today; Vector ownership
- *Don't hide these — credibility. Cite: dnstap-collector-sizing.md*

### Slide 10 — Cost: call it a toss-up
- B: appliance/VM + license; lower Splunk volume; but DDI capacity tax
- A: no dnstap license; preserves DDI headroom; higher Splunk volume
- Net: cheaper on DNS capacity, more data per Splunk dollar — not strictly cheaper

### Slide 11 — The one thing we must confirm
- **How does Data Connector source DNS data on the member?**
- If it needs query logging ON → B keeps the full performance tax
- If it consumes dnstap → A and B converge at the source
- "We sent Infoblox these questions — here's what we learned" (or "this is the open item")

### Slide 12 — Recommendation & ask
- Recommend: dnstap (Option A) for always-on forensics without DNS-path cost
- Conditions: confirm Data Connector sourcing; size Splunk volume; plan collector HA
- Ask for: decision / POC go-ahead (POC plan already exists)
- *Cite: poc-evaluation-plan.md*

---

**Backup slides:**
- B1: Full field comparison (dnstap 60+ vs query-only line)
- B2: Storage projections by event rate & retention
- B3: Objections & rebuttals table
- B4: Ports & transport detail (dnstap :6000/:6001, HEC :8088, SC4S)
