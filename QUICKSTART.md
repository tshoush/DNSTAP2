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
| Permission denied writing `/etc/...` | running without sudo | Re-run with `sudo -E`, or relocate paths in `config.toml` |
