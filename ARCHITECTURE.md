# ARCHITECTURE — DNSTAP2

End-to-end design for capturing dnstap from InfoBlox NIOS, shipping it to Splunk, and exposing it as Prometheus metrics — **no Docker, native binaries only**.

---

## 1. Goal

Replace reactive, performance-degrading DNS query logging with **always-on** dnstap telemetry from InfoBlox. The output must serve two consumers:

1. **Forensics / audit** — every event durably available in Splunk for incident investigation.
2. **Operations** — rate / latency / error metrics scraped by Prometheus and visualized in Grafana or InfoBlox-side dashboards.

Both must be true **at the same time**, from the same source, without re-engineering when one consumer changes.

## 2. Component overview

```
┌─────────────────────────────┐
│  InfoBlox Grid Master       │
│  192.168.1.224              │
│  NIOS, WAPI v2.13.7         │
│                             │
│  ┌────────────────────────┐ │
│  │ DNS daemon (per member)│ │      dnstap frames
│  │  dnstap-output → TCP   │─┼──────────────────────┐
│  └────────────────────────┘ │     (Frame Streams)  │
└─────────────────────────────┘                      │
                                                     ▼
                                ┌─────────────────────────────────┐
                                │  Receiver host (this machine)   │
                                │  192.168.1.50                   │
                                │                                 │
                                │  ┌───────────────────────────┐  │
                                │  │ Vector (single binary)    │  │
                                │  │  source: dnstap (tcp)     │  │
                                │  │  transform: enrich, l2m   │  │
                                │  │  sinks:                   │  │
                                │  │    • prometheus_exporter  │──┼──► :9598/metrics ──► Prometheus :9090
                                │  │    • file (JSONL archive) │──┼──► /var/log/dnstap/events.jsonl
                                │  │    • splunk_hec (opt.)    │──┼──► Splunk HEC
                                │  └───────────────────────────┘  │
                                │                                 │
                                │  ┌───────────────────────────┐  │
                                │  │ Prometheus (single binary)│  │
                                │  │  scrapes Vector :9598     │  │
                                │  └───────────────────────────┘  │
                                │                                 │
                                │  ┌───────────────────────────┐  │
                                │  │ dnstap2 (Python collector)│  │
                                │  │  Phase-1 debug tool only  │  │
                                │  └───────────────────────────┘  │
                                └─────────────────────────────────┘
```

## 3. Decisions and rationale

### 3.1 Why Vector for the data plane

- **Native `dnstap` source.** Vector speaks Frame Streams and decodes the protobuf payload out of the box. No glue code to maintain.
- **Single binary.** No Docker, no JVM, no Python runtime to provision. Runs under systemd as a non-root user with capability `CAP_NET_BIND_SERVICE`.
- **Multi-sink fan-out.** One source → many sinks. Splunk, files, Prometheus exporter, Kafka, S3 — all configured declaratively in one file.
- **`log_to_metric` transform.** Turns the same dnstap event stream into Prometheus-format metrics without a separate exporter.
- **Operator-friendly.** TOML config, reloadable, comprehensive `/health` and metrics surfaces of its own.

### 3.2 Why Prometheus on top

- **Pull-based, time-series.** Suited to operations dashboards and alerting on rates / latencies / RCODE distributions.
- **Same binary on the same host as Vector** keeps the loop tight; no extra network hop.
- **Vector's `prometheus_exporter` sink** is purpose-built for this — Prometheus scrapes Vector's exposed `/metrics` endpoint just like any other target.

### 3.3 Why both, not either / or

The user originally said "Vector or Prometheus." Both because:

- Vector handles **events** (rows, payloads, audit) → Splunk + archive.
- Prometheus handles **metrics** (counters, histograms) → alerting + dashboards.

They are not interchangeable. Vector emits both shapes; Prometheus consumes only the metric one. Cost of adding Prometheus on top of Vector is essentially zero: one TOML block in Vector and one binary install.

### 3.4 No Docker

- Lower operational surface — one less thing to debug at 3 a.m.
- Vector and Prometheus both ship as static binaries with no runtime deps; Docker buys us nothing for two long-lived daemons.
- Systemd gives us cleaner service supervision, logging, and resource accounting than container runtimes for this workload.

### 3.5 Cross-platform compatibility (RHEL 7 / RHEL 8+ / WSL2 / macOS)

The installers adapt at runtime to the host they're running on. There are four real compatibility surfaces:

| Surface | Old (RHEL 7.9) | Modern (RHEL 8+, Ubuntu 22+, WSL2 mirrored) | How we handle it |
|---|---|---|---|
| Python | 2.7 system | 3.10+ system | `bootstrap.sh` prompts for a 3.11+ interpreter (auto-detects candidates) and creates `.venv` from it |
| glibc | 2.17 | 2.28+ | `platform_info.uses_musl_vector` flips to `True` on glibc <2.28; we install the `linux-musl` Vector build instead of `linux-gnu` |
| systemd | 219 | 235+ | `platform_info.systemd_unit()` omits `StateDirectory=` and `AmbientCapabilities=` when systemd <235/229 — only emits directives the host's systemd actually supports |
| Service users | not auto-created | not auto-created | `lib/sysuser.ensure_system_user()` runs `useradd --system`; falls back to `root` if no root or no `useradd` (with a warning) |

WSL2 has a separate wrinkle that isn't a code issue — InfoBlox dials the **Windows host** IP, not the WSL VM IP. QUICKSTART.md documents the two solutions (mirrored networking on Win11 22H2+, or `netsh portproxy`). The receiver software runs unchanged inside WSL.

All four behaviors are exercised in `tests/test_platform_info.py` against hand-constructed `HostInfo` fixtures so we get regression coverage without needing the actual platforms in CI.

### 3.5 Why `dnstap2` (the Python collector) is *not* the production receiver

- Vector is purpose-built, battle-tested, and decodes the protobuf for us.
- `dnstap2` exists as a Phase-1 validation tool: synthetic injection, frame counting, manual decoding when we need to see exactly what InfoBlox is emitting. Keeping it around does not cost us anything; treating it as the production data plane would.

## 4. Data flow

1. **InfoBlox DNS member** is configured (via WAPI) to enable dnstap and emit Frame Streams to `192.168.1.50:6000` over TCP.
2. **Vector** binds `0.0.0.0:6000`, reads the Frame Streams handshake, and decodes each dnstap payload into a structured event with fields like `message.query.question.name`, `message.query_address`, `message.response.rcode`, timestamps, etc.
3. A **`remap` transform** projects commonly-queried fields to short, predictable names (`qname`, `qtype`, `rcode`, `client`) and adds static labels (`environment=lab`, `dns_vendor=infoblox`).
4. A **`log_to_metric` transform** derives Prometheus counters from the same enriched stream: `dnstap_queries_total{qtype, rcode}`, `dnstap_responses_total{rcode}`.
5. Three sinks fire in parallel:
   - `prometheus_exporter` → exposes `/metrics` on `:9598`.
   - `file` → JSONL append to `/var/log/dnstap/events.jsonl` (local archive, lab forensics).
   - `splunk_hec` (optional) → Splunk HEC for production audit. Events are
     rendered by the `dnstap_nios_syslog` remap into the same syslog line
     format NIOS emits with native DNS query/response logging (sourcetype
     `infoblox:dns`), so existing Splunk parsing/dashboards for InfoBlox
     syslog keep working. The `syslog_out` UDP sink sends the same lines.
   - `nios_file` (optional, `nios_log_path` / `NIOS_LOG_PATH`) → the same
     NIOS-style lines on disk for a **Splunk Universal Forwarder**
     (`scripts/install_splunk_uf.sh`). This is the route when the indexer only
     exposes a **splunktcp (S2S) forwarder input** (e.g. the Infoblox Data
     Connector port): such ports accept any TCP connection but silently
     discard raw text/syslog — only the S2S protocol indexes, and only a real
     forwarder speaks it. Verified against the Marriott indexer with
     `useACK` (indexer acknowledges blocks only after they are written to
     disk). DNS-collector has the same option (`NIOS_LOG_PATH` in
     `install_dnscollector_receiver.sh`); its lines are space-separated
     (`client <ip> <port>`) because its text formatter cannot concatenate
     tokens, while Vector's are byte-exact NIOS (`client <ip>#<port>`).
6. **Prometheus** scrapes Vector every 15 s. Operators query / alert from there.

## 5. InfoBlox configuration approach

We do not hardcode WAPI field names because they vary by NIOS build. Instead:

1. `check_infoblox.py` connects, verifies auth, and lists every field in the `member:dns` schema whose name contains `dnstap`. This produces the ground truth for the user's specific build.
2. `configure_infoblox_dnstap.py` uses heuristic substring matching (see `FIELD_HINTS` in the script) to map our config knobs to the discovered field names, snapshots existing state, and dry-runs the patch.
3. Nothing is mutated without an explicit `--apply` flag.
4. The pre-change snapshot is written to `snapshots/member-dns-pre-<ts>.json` — rollback is `PUT`-ting that file back.

## 6. Operational characteristics

| Property | Value | Notes |
|---|---|---|
| DNS-path overhead | minimal | dnstap is async / out-of-band on the NIOS side |
| Vector throughput | tens of thousands of events/sec single-instance | acceptable for any reasonable enterprise DNS load |
| Failure isolation | collector failure does **not** stall DNS | dnstap drops frames if the receiver can't keep up |
| Disk usage | dominated by JSONL archive | tune log rotation; set `vector.jsonl_path = ""` to disable |
| Auth on the wire | none in this design | acceptable on a trusted management network; for prod add TLS terminator (nginx/stunnel) in front |
| Restartability | both services restart cleanly | InfoBlox keeps trying to reconnect on its side |

### 6.1 POC operational model — configure once, then only send dnstap

The POC scripts make the whole stack a set of **persistent services** so the
only recurring action is producing dnstap:

- `scripts/poc_splunk_bringup.sh` (run once, root) installs/enables **both**
  receivers — DNS-collector (`:6001`) and Vector (`:6000`) — each writing a
  NIOS-style line file, and wires a Splunk **Universal Forwarder** that S2S-ships
  both files to `index=mi_dhcp` (`source=dnstap:dnscollector` / `dnstap:vector`).
  systemd `enable` + UF boot-start make all of it survive reboots.
- After that, `scripts/poc_simulate_dnstap.sh` (no root) feeds **both** ports in
  one command and the stack lights up end-to-end — Splunk, Prometheus, Loki,
  Grafana — with no install/Splunk script re-run. A real NIOS member pointed at
  `:6001`/`:6000` takes the identical path.
- On a **shared corporate UF**, `install_splunk_uf.sh` detects it (apps define
  `[tcpout]`, or a `deploymentclient.conf` is present) and routes only the
  dnstap monitors via `_TCP_ROUTING`, never touching the box's default routing
  or identity.

## 7. Security posture

- **TLS termination** in front of Vector (nginx or stunnel) for any non-lab deployment.
- **Splunk HEC token** never in source — env var `SPLUNK_HEC_TOKEN`.
- **InfoBlox password** never in source — env var `INFOBLOX_PASSWORD`.
- **Systemd hardening** in the generated unit files: `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=true`, dedicated unprivileged user.
- **Schema-driven WAPI calls.** No grid mutation without prior `--dry-run` review.

## 8. What's intentionally out of scope (and would be next)

- High-availability collector tier (active-active Vector pair behind a VIP).
- Sampling / filtering at the collector for cost control on very high QPS members.
- Real `dnstap2` protobuf decoding — still stubbed in the Python collector; Vector handles real decoding for the production path.
- Grafana dashboards as code (Prometheus exposes the metrics; dashboards are an exercise for a later phase).
- TLS / mTLS between InfoBlox and the collector.
- Cross-region / multi-DC topology.

## 9. Risks and rollback

| Risk | Mitigation |
|---|---|
| WAPI field names mismatch the heuristics | `check_infoblox.py --show-schema` prints the actual schema; edit `FIELD_HINTS` in `configure_infoblox_dnstap.py` |
| Receiver unreachable from grid master | InfoBlox-side rollback: clear the dnstap receiver field on the member (or PUT the snapshot) — DNS keeps serving regardless |
| Collector overload | Vector drops oldest events on back-pressure; DNS path is unaffected. Scale by running a second Vector instance on a different port and pointing additional members at it |
| Disk pressure from JSONL archive | logrotate on `/var/log/dnstap/events.jsonl`, or set `vector.jsonl_path = ""` to disable archive |
| Splunk HEC down | Vector buffers to disk; configurable retry. The Prometheus and JSONL paths are unaffected |
