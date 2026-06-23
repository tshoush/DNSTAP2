# QUICKSTART — DNSTAP2

Get from zero to dnstap-events-in-Prometheus in about ten minutes.

The scripts detect your platform and adapt. The path you take depends on **where the receiver runs**:

- **[RHEL 7.9 / CentOS 7](#rhel-79--centos-7)** — needs a manual Python install; uses Vector's musl build and a downgraded systemd unit. All handled by the scripts.
- **[RHEL 8 / 9, Rocky, Alma, Fedora](#rhel-8--9-rocky-alma-fedora)** — Python 3.11 in default repos; modern systemd.
- **[Ubuntu / Debian](#ubuntu--debian)** — Python 3.11 via apt (deadsnakes PPA on older releases).
- **[WSL2 on Windows 11](#wsl2)** — extra step: forward `:6000` from the Windows host to the WSL VM.
- **[macOS (lab only)](#macos)** — no systemd; run in foreground.

What you get at the end:
- Vector receiving dnstap frames from InfoBlox on `:6000`.
- Prometheus scraping Vector at `:9598/metrics`.
- A JSONL archive of every dnstap event in `/var/log/dnstap/events.jsonl`.
- (Optional) Events forwarded to Splunk HEC.

---

## 0. Common steps (all platforms)

```bash
git clone https://github.com/tshoush/DNSTAP2.git
cd DNSTAP2
./scripts/bootstrap.sh                # interactive — prompts for Python 3.11+ path
./scripts/setup.sh --configure-only   # prompts for IPs and local settings, saves, and stops
```

`bootstrap.sh` will:
- Detect your OS (and WSL2 / systemd version / glibc).
- Find candidate Python binaries on PATH and at well-known install locations.
- Ask for the Python binary directory, then show the best candidate and let you accept it (Enter) or type a different path.
- Validate that it is Python 3.11+ and that the `venv` module is available.
- Create `.venv/` and install the project.
- Write `.python-path` and `.python-bin-dir` with mode `0600`.
- Run the test suite to prove the bootstrap worked.

The wizard prompts for the InfoBlox Grid Master, WAPI user/password, receiver advertised IP, receiver/listen ports, Python binary directory, Prometheus/Vector addresses, and optional Splunk settings. It writes `config.toml` and `.env.dnstap2` with mode `0600`; reruns use the existing values as defaults and create timestamped backups before changing files. `--configure-only` stops after saving (use it here, before the platform-specific overrides below); `--configure` runs the same wizard and then continues straight into the full setup — connectivity check, Vector/Prometheus installs, and config rendering.

The receiver advertised IP is the IP of this host as the grid master will see it:

```toml
[receiver]
advertised_host = "192.168.1.50"      # ← THIS host's IP as the grid master will see it

[infoblox]
host = "192.168.1.224"                # pre-set
username = "admin"                     # pre-set
```
For automated runs, keep `.env.dnstap2` beside the repo or provide the same variables through the environment. Do not commit `config.toml` or `.env.dnstap2`.

> **Behind a TLS-intercepting proxy?** `setup.sh` points Python at the system CA bundle automatically and probes HTTPS before downloading; if verification still fails it falls back to unverified downloads (tarballs remain SHA256-checked). Force that mode with `./scripts/setup.sh --insecure`.

---

## RHEL 7.9 / CentOS 7

> Why this section exists: RHEL 7.9 ships Python 2.7, glibc 2.17, and systemd 219. The scripts handle the second and third for you (musl Vector + downgraded systemd unit). You handle the first.

### 1. Install Python 3.11 (one-time)

```bash
# Easiest: IUS community repo
sudo yum install -y https://repo.ius.io/ius-release-el7.rpm
sudo yum install -y python311 python311-pip

# Or from source (no extra repos):
sudo yum groupinstall -y "Development Tools"
sudo yum install -y openssl-devel bzip2-devel libffi-devel zlib-devel
curl -O https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tgz
tar xf Python-3.11.9.tgz && cd Python-3.11.9
./configure --enable-optimizations --prefix=/usr/local
make -j"$(nproc)" && sudo make altinstall
# → /usr/local/bin/python3.11
```

### 2. Run the common steps from section 0 above

When `bootstrap.sh` prompts for the Python binary directory, use `/usr/bin` if you installed IUS Python or `/usr/local/bin` if you built from source. Then accept the detected Python executable.

### 3. Install and configure

```bash
./scripts/setup.sh                # full dry-run
./scripts/setup.sh --apply        # apply WAPI changes
```

> ⚠️ **NIOS streams dnstap to ONE receiver.** `--apply` points the grid's dnstap target at *this* box — any existing receiver stops getting the stream. To run a second receiver alongside an existing one, skip `--apply` here and see [Adding a second receiver box](#adding-a-second-receiver-box).

Expected platform output:

```
host: rhel 7 (linux/x86_64), wsl=False, systemd=219, glibc=(2, 17)
installed /usr/local/bin/vector (build=x86_64-unknown-linux-musl)
wrote /etc/systemd/system/vector.service (systemd v219, user=vector)
```

The script automatically:
- Picks the **musl** Vector build (`x86_64-unknown-linux-musl`) — the gnu build needs glibc 2.28+ which RHEL 7 doesn't have.
- Generates a **systemd 219-compatible unit** (omits `StateDirectory=` and `AmbientCapabilities=` which require newer systemd).
- Creates the `vector` and `prometheus` system users via `useradd --system`.

### 4. Start services and verify

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now vector prometheus
systemctl status vector --no-pager
journalctl -u vector -n 50 --no-pager
```

---

## Adding a second receiver box

To stand up another RHEL 7.9 receiver next to an existing one (e.g. a new box alongside `192.168.1.50`):

1. On the **new** box: follow the RHEL 7.9 steps above (Python 3.11 → `bootstrap.sh` → `setup.sh --configure-only` with the new box's IP as the advertised host → `setup.sh` **without** `--apply`). Everything installs and renders; the box just has no dnstap feed yet.
2. Choose how it gets the stream:
   - **Repoint the grid** — run `./scripts/setup.sh --apply` on the new box. NIOS now streams there and the old receiver goes dark.
   - **Tee from the existing receiver** — keep NIOS pointed at the old box and have its DNS-collector forward a copy. On the old box, add an output pipeline to `/etc/dnscollector/config.yml` and route to it:

     ```yaml
     # under the tap pipeline's routing-policy:
     #   forward: [ metrics, lokiout, fileout, syslogout, newboxout ]
       - name: newboxout
         dnstapclient:
           transport: tcp
           remote-address: "<new-box-ip>"
           remote-port: 6000
     ```

     Validate and restart: `dnscollector -config /etc/dnscollector/config.yml -test-config && sudo systemctl restart dnscollector`. (This is the same mechanism the lab uses to feed Vector on `127.0.0.1:6000` from the single NIOS stream.)
3. Verify on the new box: `ss -tnp | grep :6000` shows the inbound connection, then `curl -s localhost:9598/metrics | grep dnstap_`.

---

## Alternative receiver: DNS-collector + full observability stack

Instead of (or next to) the Vector path, the standalone bash installers need no Python or `config.toml`:

```bash
sudo ./scripts/install_dnscollector_receiver.sh   # DNS-collector dnstap receiver on :6001, metrics on :9599
sudo ./scripts/install_stack.sh                   # Loki + Prometheus + Grafana + Alertmanager in one shot
./scripts/run_demo.sh --minutes 10                # synthetic dnstap traffic to light up the dashboards
```

Dashboards live in `grafana/`; the port matrix for firewall requests is in `docs/ports.md`.

---

## Splunk: two feeds, two formats (they coexist)

Both receivers can ship to Splunk at the same time; pick one or both. Events are
distinguished by sourcetype, so existing dashboards keep working:

| Feed | Format | Sourcetype | Enable with |
|---|---|---|---|
| Vector → HEC | **NIOS-style syslog lines** — same text InfoBlox emits with DNS query/response logging, so dashboards built for InfoBlox syslog need no rewrite | `infoblox:dns` | `[splunk]` in `config.toml` (Python path) or `SPLUNK_HEC_URL`/`SPLUNK_HEC_TOKEN` env (`install_dnstap_receiver.sh`) |
| DNS-collector → raw TCP | **flat-json** — one JSON object per line, machine-friendly fields (`dns.qname`, `dnstap.operation`, …) | `dnscollector:json` | `SPLUNK_TCP_ADDR=<host>:<port>` env (`install_dnscollector_receiver.sh`) |

Splunk side: the HEC feed needs a HEC token; the TCP feed needs a raw TCP input
whose sourcetype breaks events per line (`SHOULD_LINEMERGE=false`,
`LINE_BREAKER=([\r\n]+)`, `KV_MODE=json`). Example searches:
`index=dns_dnstap sourcetype="infoblox:dns"` and
`index=dns_dnstap sourcetype="dnscollector:json" | stats count by dns.qname`.

### Indexer only exposes a forwarder (S2S) port? Use the UF bridge

If the only open ingest port is a **splunktcp** input (e.g. the Infoblox Data
Connector's `:8005`), raw TCP/syslog text is accepted but never indexed — only
the Splunk-to-Splunk protocol works there. The supported route (verified
end-to-end with indexer ACKs):

```bash
# 1. DNS-collector also writes NIOS-style query/response lines to a file
NIOS_LOG_PATH=/var/log/dnscollector/nios.log sudo -E ./scripts/install_dnscollector_receiver.sh
# 2. A Universal Forwarder monitors that file and speaks S2S to the indexer
SPLUNK_IDX_ADDR=<indexer>:8005 SPLUNK_INDEX=mi_dhcp sudo -E ./scripts/install_splunk_uf.sh
# Verify:  index=mi_dhcp source="dnstap:dnscollector" | stats count by host
```

### POC one-button setup, then just send traffic

On the POC box the recommended path is the orchestrator — configure the whole
stack **once**, then never touch the install/Splunk scripts again:

```bash
# ONE TIME (as root): git pull → install BOTH receivers (DNS-collector :6001 +
# Vector :6000) → wire the Splunk UF → verify S2S → first simulated batch.
# Everything is persistent (systemd services + UF boot-start).
cd /home/ddi-auto-user/DNSTAP && git pull --ff-only
sudo -E ./scripts/poc_splunk_bringup.sh            # RECEIVER=both is the default

# FROM THEN ON, the only command you ever run — feeds both :6000 and :6001 and
# the whole stack lights up (Splunk mi_dhcp + Prometheus + Loki + Grafana):
./scripts/poc_simulate_dnstap.sh                   # no root, no re-install
```

A real NIOS member pointed at `<this-host>:6001` (DNS-collector) or `:6000`
(Vector) flows through the identical persistent path — nothing to re-run.

Shared/managed UF note: if `/opt/splunkforwarder` is an existing corporate
forwarder (already shipping elsewhere), `install_splunk_uf.sh` detects it and
routes **only** the dnstap monitors to your indexer via `_TCP_ROUTING`, leaving
its default routing and identity untouched.

Manual equivalent of the two install steps (if you don't use the orchestrator):

```bash
NIOS_LOG_PATH=/var/log/dnscollector/nios.log sudo -E ./scripts/install_dnscollector_receiver.sh
NIOS_LOG_PATH=/var/log/dnstap/nios.log       sudo -E ./scripts/install_dnstap_receiver.sh   # Vector
NIOS_LOG_PATH=/var/log/dnscollector/nios.log VECTOR_NIOS_LOG_PATH=/var/log/dnstap/nios.log \
  SPLUNK_IDX_ADDR=<indexer>:8005 SPLUNK_INDEX=mi_dhcp sudo -E ./scripts/install_splunk_uf.sh
```

Ready-made dashboards live in [`splunk/`](splunk/) (see [`splunk/README.md`](splunk/README.md)
for the full catalog and import steps). Pick by which index your events land in:

| Dashboard | Index | Use when |
|---|---|---|
| `dns_dnstap_overview.xml` | `dns_dnstap` (flat-json) | HEC / SC4S path with JSON fields (`dnstap.identity`, `dns.rcode`) |
| `dns_dnstap_ab_overview.xml` | `mi_dhcp` (UF text) | POC A/B — Vector (`:6000`) vs DNS-collector (`:6001`) side by side |
| `dns_dnstap_filterable.xml` | `mi_dhcp` (UF text) | POC — filter by **Receiver / DNS leg / domain / client IP** |

The two `mi_dhcp` boards parse the NIOS-style **text** line with search-time
`rex` (handling `CLIENT_*` and `RESOLVER_*` legs), so they need no props/transforms
on the indexer; they split Vector vs DNS-collector on the `source` field
(`dnstap:vector` / `dnstap:dnscollector`). Import any of them via Splunk UI
(Dashboards → Create → Classic → Source, paste the XML) or POST to
`/servicesNS/admin/search/data/ui/views`.

Cache-hit (in the flat-json board) is derived from response latency (&lt;2ms =
answered from cache): NIOS dnstap only emits client query/response events, so
resolver-ratio math is not possible; the DNS-collector `latency` transform must
be enabled (the installer does this).

---

## RHEL 8 / 9, Rocky, Alma, Fedora

### 1. Install Python 3.11

```bash
sudo dnf install -y python3.11 python3.11-pip
```

### 2. Run the common steps from section 0

### 3. Install and configure

```bash
./scripts/setup.sh                # dry-run
./scripts/setup.sh --apply
sudo systemctl daemon-reload
sudo systemctl enable --now vector prometheus
```

You get the full-fat systemd unit with `StateDirectory=`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`, and `ProtectSystem=full`.

---

## Ubuntu / Debian

### 1. Install Python 3.11

```bash
# Ubuntu 22.04+ has it directly:
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv python3.11-dev

# Older releases — use deadsnakes:
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv python3.11-dev
```

### 2. Run the common steps from section 0

### 3. Install and configure

```bash
./scripts/setup.sh --apply
sudo systemctl enable --now vector prometheus
```

---

## WSL2

The DNSTAP2 receiver runs **inside the WSL2 Linux VM**, but InfoBlox dials in from the LAN — and on the LAN, your **Windows host** is reachable, not the WSL VM. You must bridge the two.

### Option A — Mirrored networking (Windows 11 22H2+, easiest)

Create `%UserProfile%\.wslconfig` with:

```ini
[wsl2]
networkingMode=mirrored
```

Then from PowerShell as admin: `wsl --shutdown`. Restart your WSL session. Your Windows host IP and WSL IP are now the same. Set `receiver.advertised_host` in `config.toml` to the Windows host's LAN IP.

### Option B — `netsh portproxy` (any Windows 10/11)

From **Administrator** PowerShell on the Windows host:

```powershell
$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
netsh interface portproxy add v4tov4 `
    listenport=6000 listenaddress=0.0.0.0 `
    connectport=6000 connectaddress=$wslIp
New-NetFirewallRule -DisplayName "dnstap 6000" -Direction Inbound `
    -Protocol TCP -LocalPort 6000 -Action Allow
```

The WSL IP changes on every reboot, so re-run that on boot or put it in a startup task. Set `receiver.advertised_host` in `config.toml` to the Windows host's LAN IP.

### Inside WSL2: install Python and run

```bash
# Inside the WSL Ubuntu shell
sudo apt-get update
sudo apt-get install -y python3.11 python3.11-venv python3.11-dev

# Enable systemd inside WSL (optional but nicer; otherwise scripts run in foreground mode)
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
# Then from Windows PowerShell:  wsl --shutdown   (restart your WSL session)

# Now the normal flow:
./scripts/bootstrap.sh
cp config.example.toml config.toml
$EDITOR config.toml
export INFOBLOX_PASSWORD=infoblox
./scripts/setup.sh --apply
```

If you haven't enabled systemd inside WSL, `setup.sh` auto-detects that and switches to **foreground mode** — it prints the commands to run Vector and Prometheus directly. Run them in two `tmux` panes or two terminal tabs.

---

## macOS

> Lab only. macOS has no systemd; services run in the foreground.

```bash
brew install python@3.12 vectordotdev/brew/vector prometheus
./scripts/bootstrap.sh           # accept the homebrew python3.12
# Override install paths to user-owned dirs so we don't need sudo:
$EDITOR config.toml
# set:
#   [vector]
#   install_prefix = "/usr/local"            # or "/opt/homebrew" on Apple Silicon
#   config_path    = "/usr/local/etc/vector/vector.toml"
#   data_dir       = "/usr/local/var/vector"
#   jsonl_path     = "/usr/local/var/log/dnstap/events.jsonl"
#   [prometheus]
#   install_prefix = "/usr/local"
#   config_path    = "/usr/local/etc/prometheus/prometheus.yml"
#   data_dir       = "/usr/local/var/prometheus"

export INFOBLOX_PASSWORD=infoblox
./scripts/setup.sh --skip-install --no-systemd

# In separate terminals:
vector --config /usr/local/etc/vector/vector.toml
prometheus --config.file=/usr/local/etc/prometheus/prometheus.yml \
           --storage.tsdb.path=/usr/local/var/prometheus \
           --web.listen-address=0.0.0.0:9090
```

---

## Verify (all platforms)

```bash
# (a) Vector is happy
curl -sf http://localhost:9598/metrics | head

# (b) Prometheus sees Vector as 'up'
curl -s http://localhost:9090/api/v1/targets | grep '"health":"up"'

# (c) Frames are actually arriving
sudo tail -f /var/log/dnstap/events.jsonl

# (d) End-to-end synthetic test (stop Vector first so we can bind :6000)
sudo systemctl stop vector
./.venv/bin/python scripts/test_dnstap_flow.py --config config.toml --seconds 30
sudo systemctl start vector
```

---

## Sample Prometheus queries

```promql
# qps by qtype
sum by (qtype) (rate(dnstap_queries_total[5m]))

# NXDOMAIN rate
sum(rate(dnstap_responses_total{rcode="NXDOMAIN"}[5m]))

# top 10 talkers
topk(10, sum by (client) (rate(dnstap_queries_total[5m])))
```

Open `http://localhost:9090/graph` to plot.

---

## Rolling back

```bash
sudo systemctl disable --now vector prometheus 2>/dev/null || true

# Restore the pre-change InfoBlox snapshot:
./.venv/bin/python - <<'PY' snapshots/member-dns-pre-<timestamp>.json
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
    body.pop("_ref", None)
    client.put(ref, body)
PY
```

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `bootstrap.sh: no Python 3.11+ found` | Python not installed or too old | Follow the platform's install hint printed by bootstrap |
| `bootstrap.sh: venv module not available` | `python3-venv` package missing | `sudo apt-get install python3.11-venv` (Debian/Ubuntu) |
| `vector: error while loading shared libraries: libc.so.6: version 'GLIBC_2.28' not found` | gnu build on RHEL 7 | Should not happen — `install_vector.py` auto-picks musl. Re-run with `--force`. |
| `Failed to parse unit file: Unknown lvalue 'StateDirectory'` | systemd too old | Should not happen — unit is downgraded for systemd < 235. Re-run `install_vector.py`. |
| WSL2: InfoBlox cannot connect to receiver | WSL VM not reachable from LAN | Configure mirrored networking or `netsh portproxy` (Section [WSL2](#wsl2)) |
| `check_infoblox.py` HTTP 401 | wrong creds | Re-run `./scripts/setup.sh --configure-only` and update the password, or export `INFOBLOX_PASSWORD=...` |
| `check_infoblox.py` 0 dnstap fields | NIOS build doesn't expose dnstap via WAPI | Enable in Grid Manager UI, or upgrade NIOS |
| Vector starts but `events.jsonl` stays empty | InfoBlox not pointed at this host, or firewall | Check `receiver.advertised_host`; allow inbound TCP/6000 from grid master |
| Prometheus target shows `down` | metrics port not listening | `curl localhost:9598/metrics`; check `journalctl -u vector` |
| Vector `active` but `nios.log` frozen / Splunk `source="dnstap:vector"` empty; sim prints `no ACCEPT within timeout` | Vector's framestream **accept queue wedged** — `ss -ltnp \| grep 6000` shows Recv-Q > backlog (e.g. `129 / 128`) so it stops accepting connections | `sudo systemctl restart vector` (graceful stop waits ~60–90s; or force from a 2nd session: `sudo systemctl kill -s SIGKILL vector && sudo systemctl reset-failed vector && sudo systemctl start vector`). Then feed once and confirm Recv-Q is `0`. |
| Permission denied writing `/etc/...` | running without sudo | Re-run with `sudo -E`, or relocate paths in `config.toml` |
