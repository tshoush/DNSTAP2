# InfoBlox Ops Playbook — Enable dnstap to the DNSTAP2 Collector

**Audience:** DDI / InfoBlox operations team.
**Scope:** the **InfoBlox (NIOS) side only** — enabling dnstap on a DNS member and
pointing it at the DNSTAP2 collector. The collector/Prometheus/Grafana stack is
already installed and running by the telemetry team; this playbook does **not**
touch that side.

**Outcome:** the chosen NIOS DNS member streams a dnstap event for every query /
response to the collector over **TCP 6001**. This is **out-of-band, read-only
telemetry** — it does not change resolution behavior or answers.

---

## 0. Fill these in before you start

| Variable | Value (fill in) | Notes |
|---|---|---|
| Grid Master IP / host | `________` | e.g. `162.130.128.10` |
| WAPI user (admin) | `________` | e.g. `apitestuser` (needs DNS member write) |
| **Collector IP** | `________` | the DNSTAP2 telemetry host, e.g. `172.25.15.234` |
| **Collector port** | **`6001`** | DNS-collector receiver (Vector path uses 6000) |
| First **test member** (FQDN) | `________` | pick ONE low-risk member, not the Grid Master |
| Change window | `________` | see §6 — a DNS service restart on the member may be required |

> There is **no fixed "dnstap port."** `6001` is the port the DNSTAP2 DNS-collector
> listens on. Use `6000` only if you are pointing the member at the Vector receiver.

---

## 1. Prerequisites & access

- WAPI/admin credentials with permission to edit **member DNS** properties.
- Network path open: **DNS member → Collector : TCP 6001** (one direction; the
  stream is unidirectional, so a single stateful rule is enough). See
  [firewall-ports.md](firewall-ports.md).
- Decide the **egress interface** (see §7): by default NIOS uses **LAN1**; if you
  run a **MGMT** port, you may prefer to keep telemetry off the production data plane.
- A change/rollback window agreed (§6).

---

## 2. Pre-flight checks (do NOT skip)

**2a. Collector is reachable from the member's network — TCP 6001.**
From a host on the member's network (or the member shell if available):
```bash
nc -zv <COLLECTOR_IP> 6001        # expect: succeeded / Connected
# no nc?  ->  timeout 3 bash -c '</dev/tcp/<COLLECTOR_IP>/6001' && echo OPEN || echo CLOSED
```
If this fails, stop — fix the firewall rule `DNS member → <COLLECTOR_IP>:6001/tcp`
first. dnstap will silently not deliver otherwise.

**2b. Confirm the collector is listening** (telemetry team / collector host):
```bash
ss -lntp | grep 6001
curl -s http://127.0.0.1:9599/metrics | grep -c '^dnscollector_'   # > 1 = healthy
```

**2c. Confirm the grid exposes dnstap fields and capture current state.**
On the telemetry host (repo root), the read-only checker lists members and the
dnstap schema fields without changing anything:
```bash
python scripts/check_infoblox.py --config config.toml
```
Expected: `OK: InfoBlox is reachable and dnstap fields are discoverable.` and a
`dnstap-related schema fields` list (e.g. `dnstap_setting`, `enable_dnstap_queries`,
`enable_dnstap_responses`, `use_dnstap_setting`).

---

## 3. Make the change

Pick **one** path. **Path B (WAPI script) is preferred** — it snapshots state and
defaults to dry-run. Path A is the manual GUI equivalent.

### Path A — NIOS GUI (manual)
1. **Data Management → DNS → Members**, select the **test member** → **Edit**.
2. Open the member's DNS properties and find the **dnstap** section (label varies by
   NIOS build; it lives near Logging). On many builds you first tick **Override** so
   the member uses its own dnstap setting (`use_dnstap_setting`).
3. Set:
   - **Enable dnstap** ✔
   - **dnstap receiver address** = `<COLLECTOR_IP>`
   - **dnstap receiver port** = `6001`
   - **Send client queries** ✔ and **Send client responses** ✔
   - (optional) **Send resolver queries/responses** ✔ for recursive visibility
4. **Save**. If prompted, **restart DNS services** on that member (see §6).

> NIOS builds differ in exact field labels. If a label here doesn't match your build,
> map by meaning (receiver address/port, enable queries/responses). This is the same
> reason the script in Path B discovers field names rather than hardcoding them.

### Path B — WAPI via the repo script (preferred: dry-run → snapshot → apply)
Run from the telemetry host (repo root). The script **discovers** the dnstap field
names from the `member:dns` schema, **snapshots** current state to `./snapshots/`,
shows the proposed patch, and requires `--apply` to actually write.

1. **Set the target in `config.toml`** (collector + what to send):
   ```toml
   [receiver]
   advertised_host = "<COLLECTOR_IP>"   # the collector NIOS dials into
   advertised_port = 6001               # DNS-collector port (NOT 6000)

   [dnstap]
   client_queries    = true
   client_responses  = true
   resolver_queries  = true             # recursive visibility (optional)
   resolver_responses = true
   ```
   Provide the WAPI password via env (never commit it): `export INFOBLOX_PASSWORD=...`

2. **Dry-run on ONE member** (no change is written; review the patch + snapshot path):
   ```bash
   python scripts/configure_infoblox_dnstap.py --config config.toml --member <MEMBER_FQDN>
   ```

3. **Apply to that one member:**
   ```bash
   python scripts/configure_infoblox_dnstap.py --config config.toml --member <MEMBER_FQDN> --apply
   ```
   - Snapshot is written to `snapshots/member-dns-pre-<timestamp>.json` (keep it — it's
     your rollback artifact).
   - `--member` may be repeated; **omit it to target all members** (do that only after
     the single-member validation in §4 succeeds).
4. If your build uses unexpected field names, the script says so — adjust `FIELD_HINTS`
   / `--field-map` (telemetry team) rather than guessing in the GUI.

---

## 4. Validate (end-to-end)

Within a minute of the change, confirm real events are arriving **and that they are
from the member, not the synthetic demo**:

```bash
# raw events — identity should be the MEMBER's hostname, not "synthetic"
tail -f /var/log/dnscollector/dnscollector-events.jsonl

# query counter climbing on the collector exporter
curl -s http://127.0.0.1:9599/metrics | grep '^dnscollector_queries_total'

# Prometheus sees the collector target UP
#   http://<COLLECTOR_IP>:9090/targets
```
Then open **Grafana → `http://<COLLECTOR_IP>:3000`** → **DNS-collector Overview**. With
real traffic you'll see live QPS, top clients (real client IPs), top domains, and
NXDOMAIN/SERVFAIL panels populate.

> If the synthetic demo is still running you'll see **mixed** data. Tell the telemetry
> team to stop it (`./scripts/run_demo.sh --stop`) for a clean real-traffic board; the
> two are distinguishable by the `identity` field (`synthetic` vs member hostname).

**Success criteria:** events with `identity = <member FQDN>` in the JSONL, the query
counter rising, and the member showing up in the Grafana top-clients/top-domains tables.

---

## 5. Rollback

dnstap is additive and out-of-band, so rollback simply stops the telemetry; it does
not affect DNS answers.

- **Path B (script):** restore the pre-change snapshot, or re-run with dnstap disabled.
  ```bash
  # re-PUT the captured snapshot for the member (rollback artifact from §3 step 3)
  #   the snapshot file: snapshots/member-dns-pre-<timestamp>.json
  ```
  (Telemetry team can PUT the snapshot back via WAPI; this is the documented rollback.)
- **Path A (GUI):** edit the member → **uncheck Enable dnstap** (or clear the Override)
  → **Save** → restart DNS services if prompted.
- Verify rollback: the member's events stop arriving — `dnscollector_queries_total`
  for that source flatlines and no new JSONL lines carry that member's identity.

---

## 6. Risk, impact & change window

- **Impact is low by design** — dnstap copies events to a side channel; it does not sit
  in the resolution path and does not change answers. This is the whole point vs.
  traditional query logging.
- **A DNS service restart on the member may be required** for the dnstap setting to take
  effect (build-dependent). Treat enabling dnstap as a **member DNS property change** and
  schedule it in a normal low-risk window for that member. Confirm on your NIOS build
  whether a restart is triggered.
- **Start with one member.** Do not enable grid-wide on the first change. Avoid using the
  **Grid Master** as the first test member.

---

## 7. Interface & firewall notes

- **Interface:** by default NIOS sends DNS (and therefore dnstap) out the **LAN1** port.
  The dedicated **MGMT** port is off by default; enabling it lets you isolate
  management/telemetry traffic from the production data plane — the recommended posture
  for always-on telemetry. dnstap can ride the out-of-band path.
- **Firewall:** the only rule required is **DNS member → `<COLLECTOR_IP>` : TCP 6001**,
  inbound to the collector. The stream is unidirectional — no reverse rule needed.
- See [firewall-ports.md](firewall-ports.md) and [ports.md](ports.md).

---

## 8. Phased rollout

1. **One member** (low-risk, not Grid Master) → dry-run → apply → validate (§4).
2. **A small cohort** (2–3 members across sites) → confirm collector handles the
   combined volume (watch QPS and collector CPU/mem).
3. **Widen by site / role** until the desired members are streaming. Use `--member`
   repeatedly, or omit it for all members once you are confident.
4. Keep each step's pre-change **snapshot** for rollback.

---

## 9. Quick reference

| Item | Value |
|---|---|
| dnstap transport | Frame Streams (fstrm) over **TCP** |
| Collector port (DNS-collector) | **6001** |
| Collector metrics | `:9599` (`dnscollector_*`) |
| Grafana | `:3000` (admin / admin on the lab build) |
| Connectivity test | `nc -zv <COLLECTOR_IP> 6001` |
| Read-only pre-check | `python scripts/check_infoblox.py --config config.toml` |
| Configure (dry-run) | `python scripts/configure_infoblox_dnstap.py --config config.toml --member <FQDN>` |
| Configure (apply) | add `--apply` |
| Rollback artifact | `snapshots/member-dns-pre-<timestamp>.json` |
| Member field examples | `dnstap_setting`, `enable_dnstap_queries`, `enable_dnstap_responses`, `use_dnstap_setting` |

> The config script defaults to **dry-run** and **snapshots before any write** — favor
> Path B so every change is reviewable and reversible.
