# Network Architecture Diagram — DNSTAP2 DNS Telemetry

**Firewall request:** Open TCP **6000** and **6001** from **10.216.160.200 → 172.25.15.234**
**Date:** 2026-06-11   **Requested by:** tmsho448 (Marriott)

## Purpose

The InfoBlox DNS server emits **dnstap** query/response telemetry (Frame Streams
protocol over TCP). The DNS server is the **client** — it dials *into* the receiver
host and pushes telemetry. Two receiver services run side-by-side on distinct ports
for A/B validation and instant fallback.

## Connection flow

```
        SOURCE (DNS Server)                          DESTINATION (Telemetry Receiver)
  ┌──────────────────────────────┐            ┌────────────────────────────────────────┐
  │  InfoBlox NIOS DNS member     │            │  DNSTAP2 Receiver host                  │
  │  10.216.160.200               │            │  172.25.15.234                          │
  │                               │            │                                         │
  │  ┌─────────────────────────┐  │  TCP 6000  │  ┌───────────────────────────────────┐  │
  │  │ DNS daemon              │──┼────────────┼─►│ Vector  (dnstap source) :6000     │──┼─► Splunk HEC (audit)
  │  │ dnstap-output           │  │ (dnstap /  │  │   → Prometheus exporter :9598      │──┼─► Prometheus :9090
  │  │                         │  │  Frame     │  │   → JSONL archive                  │  │
  │  │                         │──┼────────────┼─►│ DNS-collector (dnstap) :6001      │──┼─► JSONL archive (A/B)
  │  └─────────────────────────┘  │ Streams,   │  │   → metrics :9599                  │  │
  │                               │  TCP 6001) │  └───────────────────────────────────┘  │
  └──────────────────────────────┘            └────────────────────────────────────────┘
         (connection initiator)                          (listener)

  Direction: outbound from 10.216.160.200, inbound to 172.25.15.234. Unidirectional push.
  Downstream sinks (Splunk, Prometheus, archives) are all on the receiver host — no
  additional firewall rules required.
```

## Flow table

| # | Source | Destination | Port/Proto | Service | Direction |
|---|--------|-------------|-----------|---------|-----------|
| 1 | 10.216.160.200 (InfoBlox DNS) | 172.25.15.234 (Receiver) | TCP/6000 | Vector dnstap receiver | DNS → Receiver |
| 2 | 10.216.160.200 (InfoBlox DNS) | 172.25.15.234 (Receiver) | TCP/6001 | DNS-collector dnstap receiver | DNS → Receiver |

## Notes for review

- **Single direction:** the DNS server only sends; the receiver only listens. No return
  data path or reverse connection is opened.
- **Two ports by design:** 6000 (Vector) and 6001 (DNS-collector) run in parallel so one
  can be validated against the other and serve as instant fallback. Both must be open.
- **No new exposure beyond these two flows** — all processing and downstream forwarding
  (Splunk, Prometheus, file archive) happens locally on 172.25.15.234.
```
