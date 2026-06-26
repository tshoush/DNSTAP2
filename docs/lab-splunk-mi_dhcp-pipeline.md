# Lab pipeline — InfoBlox dnstap → Vector → local Splunk (`mi_dhcp`)

What we stood up and validated in the lab: real InfoBlox DNS queries land in a
local Splunk in the **same syslog format NIOS produces with query logging**, with
**no authorization** required on the Splunk input.

```
dig @192.168.1.222 ──▶ InfoBlox DNS member .222
        │  (member dnstap, ADP-gated checkbox; emits CLIENT_QUERY + CLIENT_RESPONSE)
        ▼
   192.168.1.50:6000  Vector  (native dnstap source)
        │  dnstap_enriched → dnstap_nios_syslog  (exact NIOS `named` line)
        ▼
   [sinks.splunk_mi_dhcp]  socket/tcp ──▶ 192.168.1.100:5514
        ▼
   Splunk (docker, on the Mac)  raw TCP/UDP input :5514  → index mi_dhcp
                                                            sourcetype infoblox:dns
```

Search phrase: **`index=mi_dhcp`** · Dashboard: **`/app/search/dnstap_overview`**.

## Why Vector `:6000` (not DNS-collector `:6001`) for the Splunk feed

| | Vector `:6000` | DNS-collector `:6001` |
|---|---|---|
| Splunk format | **exact NIOS `named` syslog** (`infoblox:dns`) | flat-JSON only |
| Receives from `.222` | directly (no tee) | directly |
| dnstap fidelity | full stream, **ADP-independent** | `latency` transform pairs q/r — can hide the query line when ADP is off (see `infoblox-dnstap-extract.md` §5a) |
| Best for | **Splunk / forensics** | Prometheus/Grafana **metrics** |

Run both side-by-side if you also want the DNS-collector metrics/dashboards; use
**Vector for the Splunk feed**.

## Changes made (for reproduction / rollback)

### 1. InfoBlox (`.222`, via Grid Manager WAPI v2.13)
- `member:dns` `dnstap_setting.dnstap_receiver_port`: **6001 → 6000** (still
  `192.168.1.50`) so `.222` feeds Vector directly. Requires a DNS service restart
  to apply (`grid` `_function=restartservices`, services `["DNS"]`, member
  `infoblox222.localdomain`).
- `enable_dnstap_queries`/`responses` already `true`; `use_dnstap_setting=true`.
- ADP (`member:threatprotection.enable_service`) left **enabled** (was toggled
  during testing, then restored).

### 2. Receiver host `.50` (`/etc/vector/vector.toml`)
Added a socket sink that ships the NIOS-syslog lines to the Mac's open Splunk
input (backup saved as `vector.toml.bak-*`, then `sudo systemctl restart vector`):

```toml
[sinks.splunk_mi_dhcp]
type = "socket"
inputs = ["dnstap_nios_syslog"]
mode = "tcp"
address = "192.168.1.100:5514"   # the Mac running the Splunk container
encoding.codec = "text"
```

> Note: a pre-existing `[sinks.splunk_hec]` on `.50` points at the Mac's HEC
> (`:8088`) with a stale token/index and logs `403 Forbidden` — harmless to this
> path; remove it to quiet the logs.

### 3. Local Splunk (docker, `docker/stack`)
- Added a **Splunk** service to `docker/stack/docker-compose.yml`
  (`platform: linux/amd64` for Apple Silicon). Web `:8000`, HEC `:8088`, plus
  **raw input `:5514` tcp+udp**. Admin password + HEC token come from a gitignored
  `docker/stack/.env` (see `.env.example`).
- Created index **`mi_dhcp`** and **no-auth raw TCP/UDP inputs on `:5514`**
  (`sourcetype=infoblox:dns`, `connection_host=ip`). Raw inputs need no token.
- Set sourcetype `infoblox:dns` `DATETIME_CONFIG=CURRENT`, `SHOULD_LINEMERGE=false`
  so events land at receipt time (visible in recent windows) one-line-per-event.
- Dashboard **`dnstap_overview`** (app `search`): totals, query-rate timechart,
  top qnames/clients, qtype/rcode pies, recent raw-event table.

A self-contained **`vector` service** is also defined in the compose (config in
`docker/stack/vector/vector.toml`) — it can receive dnstap locally (e.g. from
`scripts/dnstap_synth.py`) and ship the same NIOS-syslog format to Splunk HEC,
for a demo that doesn't depend on `.50`. The production lab path above uses
`.50`'s Vector instead.

## Verify

```bash
# fire real queries at the DNS member
dig @192.168.1.222 example.com A
for i in $(seq 1 20); do dig +short @192.168.1.222 test$i.ddi.com; done

# Splunk (admin / value from docker/stack/.env)
#   http://localhost:8000  →  index=mi_dhcp
#   dashboard: http://localhost:8000/en-US/app/search/dnstap_overview

# health of the .50 forwarding sink
curl -s http://192.168.1.50:9598/metrics | grep splunk_mi_dhcp | grep sent_events_total
```

## Known fragility
- If Vector on `.50` is restarted while `.222` points at `:6001`, the
  DNS-collector→Vector tee can drop (reconnect with `sudo systemctl restart
  dnscollector`). Pointing `.222` directly at `:6000` (current setup) removes that
  tee dependency.
- Splunk's container has a `minFreeSpace` disk guard (default 5000 MB) — keep the
  Docker VM above it or searches/indexing pause.
