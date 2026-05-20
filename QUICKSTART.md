# QUICKSTART — DNSTAP2

Get from zero to dnstap-events-in-Prometheus in about ten minutes.

> Assumes: Linux (Ubuntu / RHEL / Debian) with systemd, `python3.11+`, `sudo` available, network reachability to the InfoBlox grid master at **192.168.1.224**, and an IP on this host reachable *back from* the grid master on **TCP/6000**. macOS notes are at the bottom.

---

## 0. What you'll have at the end

- Vector receiving dnstap frames from InfoBlox on `:6000`.
- Prometheus scraping Vector at `:9598/metrics`.
- A JSONL archive of every dnstap event in `/var/log/dnstap/events.jsonl`.
- (Optional) Events forwarded to Splunk HEC.
- A reusable, idempotent setup driven by one `config.toml`.

---

## 1. Clone and bootstrap config

```bash
git clone https://github.com/tshoush/DNSTAP2.git
cd DNSTAP2
cp config.example.toml config.toml
```

Edit `config.toml` and set the **two values you must change**:

```toml
[receiver]
advertised_host = "192.168.1.50"      # ← THIS host's IP, as the grid master will see it

[infoblox]
host = "192.168.1.224"                # ← already set; confirm it
username = "admin"                     # ← already set; confirm it
```

Set the password via environment variable, not in the file:

```bash
export INFOBLOX_PASSWORD=infoblox
```

(For Splunk forwarding, also set `[splunk].enabled = true`, `[splunk].hec_url = "..."`, and `export SPLUNK_HEC_TOKEN=...`.)

---

## 2. Verify connectivity to InfoBlox

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -q -e ".[dev]"
python scripts/check_infoblox.py --config config.toml
```

Expected output (abbreviated):

```
InfoBlox grid master : 192.168.1.224
WAPI version         : v2.13.7
User                 : admin
TLS verify           : False
---
grid               : infoblox.example.local (ref=grid/...)
members            : 1
  - infoblox.example.local (PHYSICAL)
member:dns objects : 1
dnstap-related schema fields: 8
  - dnstap_setting
  - enable_dnstap_queries
  - enable_dnstap_responses
  - dnstap_send_client_response_messages
  ...
---
OK: InfoBlox is reachable and dnstap fields are discoverable.
```

If `dnstap-related schema fields: 0`, your NIOS build does not expose dnstap via WAPI on this version. Open the NIOS Grid Manager UI to enable it manually, or upgrade.

---

## 3. Install Vector and Prometheus

```bash
sudo -E ./scripts/setup.sh --skip-install   # dry-run with no installs first
```

When that looks good, install:

```bash
sudo -E ./scripts/setup.sh
```

(`-E` preserves `INFOBLOX_PASSWORD`.) This will:

1. Re-run the connectivity check.
2. Download Vector and Prometheus binaries into `./vendor/`.
3. Install them to `/usr/local/bin/`.
4. Write systemd units at `/etc/systemd/system/{vector,prometheus}.service`.
5. Render `/etc/vector/vector.toml` and `/etc/prometheus/prometheus.yml`.
6. **Dry-run** the InfoBlox WAPI patch and print the proposed change.

Read the printed patch carefully. Then enable services:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now vector
sudo systemctl enable --now prometheus

systemctl status vector --no-pager
systemctl status prometheus --no-pager
```

---

## 4. Apply the InfoBlox dnstap configuration

```bash
sudo -E ./scripts/setup.sh --apply
```

This re-runs the whole flow but now passes `--apply` to `configure_infoblox_dnstap.py`, which:

1. Snapshots the current `member:dns` object(s) to `snapshots/member-dns-pre-<timestamp>.json`.
2. PUTs the patch built from `[dnstap]` and `[receiver]` in `config.toml`.

If something looks wrong afterwards, roll back by `PUT`-ting the snapshot file back to the same `_ref`.

---

## 5. Verify end-to-end

```bash
# (a) Vector is happy
sudo journalctl -u vector -n 50 --no-pager
curl -sf http://localhost:9598/metrics | head

# (b) Prometheus sees Vector as 'up'
curl -s http://localhost:9090/api/v1/targets \
  | python -c 'import json,sys; d=json.load(sys.stdin); [print(t["labels"]["job"], t["health"]) for t in d["data"]["activeTargets"]]'

# (c) Frames are actually arriving
sudo tail -f /var/log/dnstap/events.jsonl
# you should see JSON lines with .qname, .qtype, .rcode, .client etc.
```

If `events.jsonl` is empty after a few minutes:

```bash
# Stop Vector so we can bind :6000 ourselves and verify InfoBlox is dialing us.
sudo systemctl stop vector
python scripts/test_dnstap_flow.py --config config.toml --seconds 30
sudo systemctl start vector
```

This script binds the receiver port, fires a handful of synthetic queries at the grid master, and counts frames. If it sees > 0 frames, InfoBlox is emitting and the network path is fine — the issue is in Vector. If it sees 0 frames, the issue is on the InfoBlox side or in the network.

---

## 6. Sample Prometheus queries

```promql
# total queries per second, last 5 minutes, broken out by qtype
sum by (qtype) (rate(dnstap_queries_total[5m]))

# NXDOMAIN rate
sum(rate(dnstap_responses_total{rcode="NXDOMAIN"}[5m]))

# top 10 talkers (requires `client` to be label-able; see notes in vector.toml)
topk(10, sum by (client) (rate(dnstap_queries_total[5m])))
```

Open `http://localhost:9090/graph` to plot.

---

## 7. Rolling back

```bash
# Stop services
sudo systemctl disable --now vector prometheus

# Roll back InfoBlox dnstap config (restore the pre-change snapshot)
python - <<'PY'
import json, sys
from scripts.lib import config as c
from scripts.lib.infoblox import InfobloxClient
cfg = c.load("config.toml")
client = InfobloxClient(
    host=cfg.infoblox.host, username=cfg.infoblox.username, password=cfg.infoblox.password,
    wapi_version=cfg.infoblox.wapi_version, verify_tls=cfg.infoblox.verify_tls,
)
snap = json.load(open(sys.argv[1]))
for ref, body in snap.items():
    # strip read-only fields before PUTting back; tune as needed for your NIOS build.
    body.pop("_ref", None)
    client.put(ref, body)
PY snapshots/member-dns-pre-<timestamp>.json
```

---

## macOS notes (lab only, no systemd)

```bash
brew install vectordotdev/brew/vector prometheus
./scripts/setup.sh --skip-install --no-systemd
# then in separate terminals:
sudo vector --config /etc/vector/vector.toml
prometheus --config.file /etc/prometheus/prometheus.yml \
           --storage.tsdb.path /usr/local/var/prometheus \
           --web.listen-address 0.0.0.0:9090
```

You can also override the install paths in `config.toml` to user-owned directories so you don't need `sudo`:

```toml
[vector]
install_prefix = "/Users/me/.local"
config_path    = "/Users/me/.local/etc/vector/vector.toml"
data_dir       = "/Users/me/.local/share/vector"
jsonl_path     = "/Users/me/.local/share/vector/events.jsonl"

[prometheus]
install_prefix = "/Users/me/.local"
config_path    = "/Users/me/.local/etc/prometheus/prometheus.yml"
data_dir       = "/Users/me/.local/share/prometheus"
```

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `check_infoblox.py` HTTP 401 | wrong creds | `export INFOBLOX_PASSWORD=...`; re-check WAPI user |
| `check_infoblox.py` 0 dnstap fields | NIOS build doesn't expose dnstap via WAPI | enable in Grid Manager UI or upgrade |
| Vector starts but `events.jsonl` stays empty | InfoBlox not pointed at this host, or firewall | check `receiver.advertised_host`, allow inbound TCP/6000 from grid master |
| Prometheus target shows `down` | metrics port not listening | `curl localhost:9598/metrics`; check `journalctl -u vector` |
| Frames arrive but no `qname` field | `remap` transform expectations differ for your build | adjust the `[transforms.dnstap_enriched]` block in `templates/vector.toml.tmpl` and re-render |
| Permission denied writing `/etc/...` | running without sudo | re-run with `sudo -E`, or relocate paths in `config.toml` |
