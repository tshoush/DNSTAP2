---
name: deploy-verify-dnstap
description: Deploy the dnstap→Splunk/Prometheus pipeline to a real lab box and then VERIFY it end-to-end — refusing to declare success until metrics counters climb and dashboard panels show non-empty, non-merged data. Use when the user asks to deploy / stand up / ship the DNSTap receiver and confirm it actually works (against real InfoBlox and/or synthetic traffic), not just that it installed.
---

# Deploy + verify the DNSTap pipeline

Two-phase skill: **deploy** via the existing installers on the real LAN box, then
**verify** with hard acceptance criteria. "Installed cleanly" is NOT success —
success is **frames flowing and panels populated**. Do not declare done on empty
data; diagnose and fix the root cause first.

This codifies the strongest recurring workflow: ship to a real RHEL box and prove
it works against real InfoBlox + synthetic sources.

## Ground rules (from CLAUDE.md)

- The lab box is a **real LAN host reachable by direct SSH** (e.g. `192.168.1.x`).
  **Never** use Docker or localhost workarounds (`127.0.0.1`, port `2222`) to
  "reach" it. If SSH fails, fix the real path (creds, firewall, advertised host).
- Scope is **dnstap / Frame Streams over TCP only** — no DoT/DoH.
- If a step genuinely can't be completed (no SSH, InfoBlox unreachable), say so
  once and stop with a clear status — don't loop or fake a green result.

## Inputs to confirm first

1. **Target host** — the LAN IP of the receiver box (where Vector/DNS-collector runs).
2. **Receiver path** — Vector (`:6000`, port `9598`, `dnstap_*`) or DNS-collector
   (`:6001`, port `9599`, `dnscollector_*`). They coexist on distinct ports/users —
   keep them distinct. Default to whichever is already installed; ask if neither.
3. **Source(s)** — real InfoBlox grid master, synthetic generator, or both. Verify
   against **both** when available; synthetic alone proves the receiver, not the
   InfoBlox dnstap config.
4. **Splunk/dashboard** — Splunk (`dns_dnstap` index) and/or Grafana. Note which
   panels must be non-empty (e.g. QPS, query-rate, top domains).

## Phase 1 — Deploy

Run on the target box over direct SSH, from the repo root. Pick the path:

```bash
# Vector path (config.toml + .venv driven)
./scripts/setup.sh --apply            # connectivity → install Vector/Prometheus
                                      # → render configs → PUT InfoBlox dnstap config
./scripts/setup.sh                    # DRY-RUN the InfoBlox step first to preview

# DNS-collector path (standalone bash, no config.toml/venv)
sudo ./scripts/install_dnscollector_receiver.sh   # receiver on :6001
sudo ./scripts/install_stack.sh                   # Loki/Prometheus/Grafana/Alertmanager
```

InfoBlox writes are **dry-run by default** and snapshot `member:dns` first — only
`--apply` mutates the grid. Preview before applying.

## Phase 2 — Verify (the part that matters)

Two ordered stages. **Synthetic first to prove the backend, then real DNS queries
to prove the whole pipeline.** Don't skip to real queries on a backend you haven't
confirmed — and don't stop at synthetic, because it bypasses InfoBlox.

### Stage A — synthetic: verify the BACKEND (receiver → sink → Splunk/panels)

Synthetic frames are injected straight at the receiver port, so they exercise
everything *downstream* of InfoBlox without depending on the grid's dnstap config.
This isolates backend bugs (sink, index, line-breaking, panels) from
InfoBlox/network bugs. Get this green first.

```bash
# Inject synthetic dnstap traffic at the receiver
./scripts/run_demo.sh --rate 60                 # or: python scripts/dnstap_synth.py --count 200 --rate 200
./scripts/run_demo.sh --status                  # live counters

# Receiver metrics MUST climb (pick the port for your path)
curl -s http://localhost:9598/metrics | grep dnstap_       # Vector
curl -s http://localhost:9599/metrics | grep dnscollector_ # DNS-collector

# Frame smoke test (stop the receiver first per its docstring)
python scripts/test_dnstap_flow.py --config config.toml --seconds 30
```

Confirm counters climb AND Splunk/Grafana panels populate from synthetic data
before moving on. If a panel is empty here, it's a backend/sink/query bug — fix it
now, while the input is deterministic.

### Stage B — real DNS queries: verify the WHOLE PIPELINE through InfoBlox

This is the actual end-to-end test. Stop synthetic, then **send real DNS queries to
the InfoBlox NIOS DNS server**. The grid resolves them and emits genuine dnstap
`CLIENT_QUERY`/`RESPONSE` frames over its configured dnstap channel — exercising the
one path synthetic can't: the InfoBlox dnstap config → network → receiver.

```bash
./scripts/run_demo.sh --stop                    # turn OFF synthetic first

# Point real queries at the grid master's DNS service (port 53), NOT the receiver port.
GRID=<infoblox-grid-master-ip>

# light functional check — a handful of distinct names
for n in example.com www.google.com $(hostname -d) nonexistent.invalid; do
  dig @"$GRID" "$n" +short ; done

# sustained load to populate rate panels (preferred if dnsperf is available)
dnsperf -s "$GRID" -d queryfile.txt -l 60        # 60s of real query load
```

Then re-check the SAME counters and panels — they must now climb from **real grid
traffic**, and the queried names must appear as real events in Splunk
(`dns_dnstap` index) and in the dashboards. Verifying distinct real domains also
catches event-merging that uniform synthetic traffic can mask.

### Acceptance criteria — ALL must hold before declaring success

Stage A (backend, synthetic):
- [ ] Receiver metric counter (`dnstap_*` / `dnscollector_*`) is **non-zero and
      increasing** across two scrapes (not stuck).
- [ ] `test_dnstap_flow.py` reports **≥ N frames** received.
- [ ] Each required dashboard/Splunk panel shows **non-empty** data from synthetic
      traffic (Splunk `dns_dnstap` index returns events; Grafana tiles render).
- [ ] Events are **not merged/collapsed** — distinct queries appear as distinct
      events (a classic Splunk line-breaking/timestamp bug). Spot-check raw events.

Stage B (whole pipeline, real DNS queries through InfoBlox):
- [ ] After `dig`/`dnsperf` against the grid (synthetic OFF), the **same counters
      climb from real grid traffic** — proving the InfoBlox dnstap config and
      network path, not just the backend.
- [ ] The **specific domains you queried appear** as real events in Splunk and on
      the dashboards.

### When a check fails — diagnose, don't paper over

- **Counter flat / zero** → is the receiver service up? Is InfoBlox dialing the
  right host:port? On WSL2, set `receiver.advertised_host` to the Windows host LAN
  IP (InfoBlox can't address the WSL VM directly — see QUICKSTART.md).
- **Panel empty but counters climb** → the receiver works; the sink/index/query is
  wrong. Check the Splunk index name / sourcetype / time range, or the Grafana
  datasource.
- **Events merged** → Splunk line-breaking / `SHOULD_LINEMERGE` / timestamp
  extraction on the sourcetype.
- **Wrong field paths** → a pipeline change must land in **both** the template
  (`templates/vector.toml.tmpl`) and the standalone installer to stay in sync.

## Report

End with a status table: each acceptance criterion → PASS/FAIL with the observed
number (frame count, counter delta, panel/event count). If any FAIL remains after
diagnosis, report it plainly — do not call the deployment done.
