# SNMP Integration — Design & Research

> **Status: research / design only.** Nothing in this document has been installed or
> changed on any host. It describes *how* SNMP would slot into the existing DNSTAP2
> observability stack (DNS-collector → Prometheus + Loki + Alertmanager → Grafana),
> what each component would do, the ports involved, and a recommended rollout.

## 1. What you asked for, mapped to tools

| Goal | Best tool | Why |
|---|---|---|
| **System status (up/down, service health)** | Prometheus `up` + `node_exporter` (Linux hosts) + `snmp_exporter` (appliances) | One green/red signal per target; SNMP adds appliance/service status you can't get locally |
| **CPU / Memory / Disk** | `node_exporter` for hosts you control; `snmp_exporter` (+ `snmpd`) for SNMP-only devices | node_exporter is richer & simpler on Linux; SNMP is the only option for appliances like InfoBlox |
| **Send a trap** (to a corporate NMS when something breaks) | `snmp_notifier` wired to the existing **Alertmanager** | Turns Prometheus alerts into SNMP **v2c/v3 traps** to a legacy NMS |
| **Receive traps** (e.g. from InfoBlox/network gear) | `snmptrapd` or **Telegraf `snmp_trap`** → Loki / Prometheus | Brings device-originated events into the same Grafana |

Two orthogonal directions, don't confuse them:
- **Polling (pull):** *we* ask devices "what's your CPU/mem/disk?" → `snmp_exporter` / `node_exporter`.
- **Traps (push):** devices (or our Alertmanager) *send* an event the moment it happens → `snmptrapd`/Telegraf (in) and `snmp_notifier` (out).

## 2. Where SNMP fits the existing stack

```
                          ┌─────────────────── existing DNSTAP2 ───────────────────┐
  InfoBlox NIOS  ──dnstap:6001──► DNS-collector ──► Prometheus :9090 ──► Grafana :3000
       │  ▲                                            ▲   │
       │  │                                            │   └──► Alertmanager :9093
       │  │ (NEW) SNMP                                 │                 │
       │  └──────────── poll ◄── snmp_exporter :9116 ──┘                 │ (NEW)
       │     CPU/mem/temp/svc      (one proxy, many devices)             ▼
       │     ibPlatformOne MIB                                     snmp_notifier :9464
       │                                                                 │ trap
       └──── trap (events) ──► snmptrapd / Telegraf :162 ─► Loki :3100   ▼
                                  (NEW, device→stack)               Corporate NMS :162

  Telemetry host(s) ──► node_exporter :9100 ──poll──► Prometheus   (NEW, host CPU/mem/disk)
```

Every new piece is a **single static Go binary + systemd unit** (or net-snmp from the RHEL
repos) — consistent with the project's "native binaries, no Docker, no JVM" rule, and all run
on RHEL 7 (glibc 2.17) like the rest of the stack.

## 3. Component reference (proposed)

| Component | Role | Listen / talks to | Binary | Metric/label prefix |
|---|---|---|---|---|
| **node_exporter** | Host CPU/mem/disk/net/systemd of Linux boxes you control | `:9100` (scraped by Prometheus) | static Go | `node_*` |
| **snmp_exporter** | SNMP **polling proxy** for appliances/network gear (incl. InfoBlox) | `:9116` `/snmp?target=…` | static Go | `snmp_*` (renamed per module) |
| **snmpd** (net-snmp) | SNMP agent *on* a Linux host (only if you want host metrics via SNMP, not node_exporter) | `udp/161` on each host | RHEL pkg | HOST-RESOURCES-MIB / UCD-SNMP-MIB |
| **snmptrapd** (net-snmp) or **Telegraf** `snmp_trap` | **Receive** traps from devices → forward to Loki/Prometheus | `udp/162` | RHEL pkg / static Go | logs (Loki) or `snmp_trap_*` |
| **snmp_notifier** | **Send** Alertmanager alerts as SNMP traps to an NMS | webhook `:9464`, traps → NMS `udp/162` | static Go | — |

## 4. Capability A — Host metrics (CPU / Memory / Disk)

Two ways; you can use either or both.

### A1. `node_exporter` (recommended for Linux hosts you own — the telemetry box, and DNS hosts if you can place an agent)
- Exposes hundreds of metrics out of the box: `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_filesystem_avail_bytes`, disk I/O, network, and **systemd unit state** (`--collector.systemd`) — so you can alert on `dnscollector.service`/`prometheus.service` being down. [node_exporter]
- Prometheus scrape:
  ```yaml
  - job_name: node
    static_configs:
      - targets: ['localhost:9100']          # add each host here
  ```
- Typical panels: CPU %, mem used %, disk used % per mount, load, uptime. Grafana dashboard **1860 "Node Exporter Full"** is the de-facto standard.

> node_exporter is **not** SNMP — it's Prometheus-native. It's the simplest, richest way to get
> CPU/mem/disk for Linux you control. Use SNMP (A2) only where you can't run an agent.

### A2. CPU/mem/disk **via SNMP** (`snmpd` + `snmp_exporter`)
For boxes where SNMP is mandated, or that you can't put node_exporter on:
- Run `snmpd` (net-snmp, in RHEL repos) on each host; it serves **HOST-RESOURCES-MIB** (`hrStorageUsed`/`hrStorageSize` for disk & RAM, `hrProcessorLoad` for CPU) and **UCD-SNMP-MIB** (`ssCpuIdle`, `memAvailReal`, `dskPercent`).
- Poll it with `snmp_exporter` (below). This is the same mechanism used for appliances.

## 5. Capability B — SNMP polling with `snmp_exporter` (appliances incl. InfoBlox)

`snmp_exporter` runs **once, centrally**, and acts as a proxy: Prometheus hands it a target IP at
scrape time, the exporter does the SNMP walk and returns Prometheus metrics. *A single instance can
poll thousands of devices.* Default port **9116**. [snmp_exporter]

### Prometheus scrape job (the key relabel pattern)
```yaml
scrape_configs:
  - job_name: 'snmp'
    static_configs:
      - targets:                       # the DEVICES to poll
        - 192.168.1.222                # an InfoBlox member
        - 10.0.0.5                     # a switch, etc.
    metrics_path: /snmp
    params:
      auth: [infoblox_v3]              # an auth defined in snmp.yml
      module: [if_mib]                 # one or more modules
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9116    # rewrite to the exporter itself
```
(Relabeling passes the device IP as `__param_target` while the connection goes to the exporter.) [snmp_exporter]

### `snmp.yml` — auths & modules
- **auths** hold credentials. For security use **SNMPv3**:
  ```yaml
  auths:
    infoblox_v3:
      version: 3
      username: dnstap_ro
      security_level: authPriv
      auth_protocol: SHA           # SHA / SHA256 …
      priv_protocol: AES           # AES / AES256 …
      password:      ${SNMP_AUTH_PW}     # via --config.expand-environment-variables
      priv_password: ${SNMP_PRIV_PW}
  ```
  > Community strings (v1/v2c) are sent in cleartext and are **not** secrets — prefer v3. Keep
  > passwords in env vars, mirroring the project's `INFOBLOX_PASSWORD`/`SPLUNK_HEC_TOKEN` convention. [snmp_exporter]
- **modules** are walk definitions (which OIDs to collect, how to rename/label them). The bundled
  `snmp.yml` already includes generic modules (`if_mib`, etc.). For vendor MIBs (InfoBlox) you
  regenerate `snmp.yml` with the **generator**.

### The generator (for InfoBlox & custom MIBs)
- The `generator` reads a `generator.yml` listing the MIB objects you want, compiles the vendor MIB
  files, and emits a tailored `snmp.yml`. Run it once when you add/define a device type. [snmp_exporter]
- For InfoBlox you'd drop the Infoblox MIBs (see §7) into the generator's MIB path and reference the
  `ibPlatformOne` objects (CPU, memory, temperature, service status) plus standard `if_mib`/
  `host-resources` walks.

## 6. Capability C — Traps

### C1. Receiving traps (device → stack)
Bring InfoBlox/router/switch event traps into the same Grafana:
- **Option 1 — Telegraf `snmp_trap` input → Loki:** Telegraf listens for traps (plain UDP, default
  **162**), does MIB lookup so fields are human-named, and can output to Loki (logs) and/or to a
  metrics store. Traps then appear in Grafana next to DNS events. [telegraf-snmptrap]
- **Option 2 — net-snmp `snmptrapd` → syslog → Loki:** `snmptrapd` receives traps and writes
  them to syslog; rsyslog/Promtail/Vector forwards to Loki. Simpler, log-only.
- **Caveat:** UDP **162 is privileged** — the receiver needs `CAP_NET_BIND_SERVICE` (or a port
  redirect), the same pattern the project already handles in systemd units. [telegraf-snmptrap]

### C2. Sending traps (stack → NMS) with `snmp_notifier`
To page a legacy enterprise NMS when a DNSTAP2 alert fires, **no change to alert rules** — just add a
receiver to the **existing Alertmanager**:
```yaml
# alertmanager.yml
receivers:
  - name: snmp_notifier
    webhook_configs:
      - send_resolved: true
        url: http://127.0.0.1:9464/alerts
```
`snmp_notifier` (webhook on **:9464**) maps each alert to a trap OID and emits **v2c/v3** traps to
the NMS; `--snmp.destination=<nms>:162`, `--snmp.trap-oid-label=oid`, with a default OID for alerts
that don't carry one. `send_resolved` makes it emit a "cleared" trap when the alert resolves. [snmp_notifier]

> This reuses the alert rules already shipped by `install_alertmanager.sh` (receiver-down, silent
> stream, NXDOMAIN/SERVFAIL spikes, tunneling heuristic) — they'd now also reach the corporate NMS.

## 7. InfoBlox NIOS specifics

InfoBlox NIOS is a first-class SNMP citizen — this is the cleanest way to monitor the **appliances**
themselves (you can't run node_exporter on them):

- **Enterprise OID prefix:** all Infoblox objects begin `.1.3.6.1.4.1.7779` (IANA enterprise **7779**). Access is **read-only**. SNMP **v1/v2c/v3** supported. [infoblox-snmp]
- **MIB tree** (under `ibProduct → ibOne`):
  | MIB | Provides |
  |---|---|
  | **ibPlatformOne** | **CPU utilization, memory utilization, CPU temperature**, replication status, average DNS request latency, DNS security alerts, **Infoblox service status** |
  | **ibDNSone** | DNS-specific statistics |
  | **ibDHCPOne** | DHCP-specific statistics |
  | **ibTrap** | Defines the **traps NIOS sends** (the events for §6.1) |
- **Poll** `ibPlatformOne` via `snmp_exporter` (generator + Infoblox MIBs) → host health of every grid
  member in Grafana, alongside the dnstap query telemetry you already collect.
- **Traps:** point NIOS's trap receivers at our `snmptrapd`/Telegraf (§6.1) to capture grid events
  (service down, replication issues, HA failover, security alerts).
- **Enable:** SNMP is configured per-grid/member in NIOS (Grid/Member properties → SNMP: community
  or v3 user, allowed pollers, trap receivers). Confirm exact field names on your NIOS build. [infoblox-snmp]
- **Interface note:** SNMP polling and traps can ride the **MGMT** interface — consistent with the
  out-of-band guidance in this repo's dnstap interface research (keep telemetry off the data plane).

## 8. Ports & firewall additions (summary)

| Direction | Port | Purpose |
|---|---|---|
| Prometheus → node_exporter | TCP **9100** | host CPU/mem/disk |
| Prometheus → snmp_exporter | TCP **9116** | scrape the SNMP proxy |
| snmp_exporter → devices | UDP **161** | SNMP GET/WALK (polling) |
| devices → snmptrapd/Telegraf | UDP **162** | inbound traps |
| Alertmanager → snmp_notifier | TCP **9464** | alert webhook |
| snmp_notifier → NMS | UDP **162** | outbound traps |

These slot next to the existing `6001/9599/9090/3100/3000/9093` (see `docs/firewall-ports.md`).

## 9. Grafana

- **Node Exporter Full** (dashboard ID **1860**) for host CPU/mem/disk.
- A generic **SNMP**/interface dashboard for `snmp_exporter` series; plus a small custom panel set for
  the Infoblox `ibPlatformOne` gauges (CPU%, mem%, temp, service status) — provisioned the same way
  `install_grafana.sh` provisions the DNS-collector dashboard.
- Traps land in **Loki** (if using Telegraf/snmptrapd→Loki), so a Logs panel filtered to the trap
  job shows device events beside DNS events.

## 10. Recommended rollout (phased, low-risk)

1. **Host metrics first** — `node_exporter` on the telemetry host(s); add a `node` scrape job; import
   dashboard 1860. Immediate CPU/mem/disk + systemd service-up alerting. *(No SNMP yet.)*
2. **Poll InfoBlox** — stand up one `snmp_exporter`; enable SNMPv3 read-only on one NIOS member;
   generate `snmp.yml` with the Infoblox MIBs; add the `snmp` scrape job for that member; validate
   `ibPlatformOne` CPU/mem appear; then widen to all members + network gear.
3. **Outbound alerts → NMS** — add `snmp_notifier` + the Alertmanager receiver; test with a synthetic
   alert; confirm the NMS sees the trap and the resolve.
4. **Inbound traps** — add Telegraf `snmp_trap` (or `snmptrapd`) on UDP 162 → Loki; point NIOS/device
   trap receivers at it; add a Grafana Logs panel.

Each phase is independent and reversible (its own binary/user/unit), matching the project's
side-by-side, instant-fallback philosophy. Mirror the existing standalone installers
(`install_*.sh`) when you build these out.

## 11. Security notes

- Prefer **SNMPv3 authPriv** everywhere; treat v1/v2c community strings as non-secret and avoid on
  untrusted segments.
- Keep SNMP/trap credentials in **env vars**, never committed (same rule as `INFOBLOX_PASSWORD`).
- Restrict snmpd/snmptrapd to specific poller/trap-source IPs; firewall 161/162 to the telemetry host.
- Run SNMP over the **MGMT/out-of-band** path where possible.

## 12. What this does *not* change

This is documentation only. No exporter, agent, or config was installed; Prometheus, Grafana, Loki,
Alertmanager, and DNS-collector are untouched. Building any phase above is a separate, explicit step.

---

### Sources
- Prometheus **snmp_exporter** — README, config, relabeling, generator, SNMPv3, port 9116: <https://github.com/prometheus/snmp_exporter>
- Prometheus **node_exporter** — host CPU/mem/disk/systemd, port 9100: <https://github.com/prometheus/node_exporter> · <https://prometheus.io/docs/guides/node-exporter/>
- **snmp_notifier** (Alertmanager → SNMP traps, webhook :9464, v2c/v3): <https://github.com/maxwo/snmp_notifier>
- **Telegraf `snmp_trap`** input (receive traps, UDP 162, MIB lookup, → Loki): <https://docs.influxdata.com/telegraf/v1/input-plugins/snmp_trap/> · <https://www.influxdata.com/integrations/snmp_trap-loki/>
- **InfoBlox NIOS SNMP** — MIB hierarchy (ibTrap/ibPlatformOne/ibDNSone/ibDHCPOne), enterprise OID 7779, CPU/memory/temp/service status, read-only, v1/v2c/v3: <https://docs.infoblox.com/space/nios90/280401198> · <https://docs.infoblox.com/space/nios90/280760493/SNMP+MIB+Hierarchy> · <https://docs.infoblox.com/space/nios90/280662492>
