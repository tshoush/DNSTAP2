# DNSTAP2

Native, no-Docker pipeline for capturing DNS query telemetry from **InfoBlox NIOS** via **dnstap** and shipping it to **Splunk** + **Prometheus**.

> Built to replace reactive DNS query logging — which we have to turn off because it degrades DNS performance — with always-on, out-of-band dnstap telemetry. See [ARCHITECTURE.md](ARCHITECTURE.md) for the design and [QUICKSTART.md](QUICKSTART.md) for the 10-minute setup walkthrough.

## What this repo gives you

| | |
|---|---|
| **Vector config (generated)** | Native dnstap source → Splunk HEC + JSONL archive + Prometheus exporter |
| **Prometheus config (generated)** | Scrapes Vector for metrics |
| **Python WAPI scripts** | Discover schema, configure dnstap on InfoBlox, dry-run by default with snapshot+rollback |
| **Python install scripts** | Download and install Vector and Prometheus binaries, write systemd units |
| **Python `dnstap2` library** | Tiny Frame Streams reader for Phase-1 validation and debugging |
| **`scripts/setup.sh`** | One-shot orchestrator: connectivity check → install → render configs → InfoBlox dry-run |

## Stack

| Component | Role | Notes |
|---|---|---|
| InfoBlox NIOS | DNS source | grid master at `192.168.1.224`, WAPI `v2.13.7` |
| Vector | Receiver + router + metrics exporter | single static binary, runs under systemd |
| Prometheus | Time-series store for ops dashboards | single static binary, scrapes Vector |
| Splunk HEC | Forensic audit log (optional) | enable via `[splunk].enabled` in `config.toml` |
| Python 3.11+ | Operational scripts | stdlib only at runtime, no Docker, no JVM |

## Layout

```
DNSTAP2/
├── ARCHITECTURE.md             # design + decisions + rollback
├── README.md                   # this file
├── QUICKSTART.md               # 10-minute walkthrough
├── config.example.toml         # copy to config.toml and edit
├── pyproject.toml              # dnstap2 lib + dev tooling
├── src/dnstap2/                # the Python library (Phase-1 debug tool)
│   ├── framestream.py          # stdlib Frame Streams reader (tested)
│   ├── decoder.py              # protobuf decoder stub (Vector does real decoding)
│   ├── collector.py            # socket accept loop
│   ├── cli.py                  # `dnstap2` console script
│   └── sinks/                  # stdout, jsonl, splunk HEC
├── tests/                      # pytest
├── scripts/
│   ├── bootstrap.sh            # interactive Python detection + venv creation
│   ├── setup.sh                # one-shot orchestrator (auto-detects WSL/no-systemd)
│   ├── lib/                    # shared helpers (config, WAPI, platform, sysuser)
│   ├── check_infoblox.py       # connectivity + schema probe
│   ├── configure_infoblox_dnstap.py  # WAPI dnstap config (dry-run by default)
│   ├── install_vector.py       # download + install Vector binary
│   ├── install_prometheus.py   # download + install Prometheus binary
│   ├── render_vector_config.py
│   ├── render_prometheus_config.py
│   └── test_dnstap_flow.py     # end-to-end frame-count smoke test
├── templates/
│   ├── vector.toml.tmpl
│   └── prometheus.yml.tmpl
├── docs/design.md              # design notes for the Python library
└── vendor/                     # downloaded binaries (gitignored)
```

## Supported platforms

| Platform | Vector build | Systemd | Notes |
|---|---|---|---|
| **RHEL / CentOS / Rocky / Alma 7.x** | `linux-musl` (auto) | v219 — unit downgraded automatically | Needs Python 3.11+ from IUS or from source (bootstrap prints commands) |
| **RHEL / CentOS / Rocky / Alma 8.x and 9.x** | `linux-gnu` | v239+ — full hardening | Python 3.11+ from `dnf install python3.11` |
| **Ubuntu / Debian (native)** | `linux-gnu` | yes | `apt install python3.11 python3.11-venv` (deadsnakes PPA on older releases) |
| **Ubuntu under WSL2 (Windows 11)** | `linux-gnu` | yes if `[boot] systemd=true` in `/etc/wsl.conf`, else foreground | **Networking note**: InfoBlox dials your *Windows* host, not the WSL VM. Use mirrored networking or `netsh portproxy`. See [QUICKSTART.md](QUICKSTART.md#wsl2). |
| **macOS** (lab only) | `apple-darwin` | n/a — foreground mode | `brew install python@3.12` |

All platform-specific details (glibc version → musl build, systemd version → unit syntax) are detected at install time. You don't have to think about it.

## Prerequisites

- **Python 3.11+** (we use stdlib `tomllib`) — `bootstrap.sh` prompts for it interactively with auto-detection.
- Reachability: this host → InfoBlox grid master on `TCP/443` (WAPI), and grid master → this host on `TCP/6000` (dnstap).
- `sudo` for writing systemd units and `/etc/` config files. Override `install_prefix` in `config.toml` to a user-owned dir to skip `sudo`.

## Quick start

The short version — full walkthrough in [QUICKSTART.md](QUICKSTART.md):

```bash
git clone https://github.com/tshoush/DNSTAP2.git
cd DNSTAP2

./scripts/bootstrap.sh                # prompts for Python bin dir/path, creates .venv, installs
./scripts/setup.sh --configure-only   # prompts for IPs, writes config + .env.dnstap2, stops

./scripts/setup.sh                 # dry-run end-to-end
./scripts/setup.sh --apply         # actually push the InfoBlox dnstap config
```

### POC fast path — configure once, then just send dnstap

For a Splunk-feeding POC (both receivers + a Universal Forwarder to an
S2S-only indexer like the Infoblox Data Connector's `:8005`), one command wires
the whole stack persistently; after that you only ever send dnstap:

```bash
# ONE TIME (root): installs DNS-collector :6001 + Vector :6000, wires the UF to
# index=mi_dhcp on the indexer, verifies S2S. Everything is a persistent service.
sudo -E ./scripts/poc_splunk_bringup.sh                 # RECEIVER=both by default

# FROM THEN ON: feed both :6000 and :6001 and watch Splunk + Grafana light up.
./scripts/poc_simulate_dnstap.sh                        # no root, no re-install
```

A real NIOS member pointed at `<host>:6001` (DNS-collector) or `:6000` (Vector)
uses the same persistent path. Details in
[QUICKSTART.md](QUICKSTART.md#poc-one-button-setup-then-just-send-traffic).

Verify:

```bash
python scripts/test_dnstap_flow.py --config config.toml
curl -s http://localhost:9598/metrics | grep dnstap_
open  http://localhost:9090
```

## Configuration

Everything is driven by `config.toml`. Run `./scripts/setup.sh --configure-only` to create or safely update it; existing values are shown as defaults and the previous file is backed up. (`--configure` runs the same wizard, then continues into the full setup.) Secrets entered in the wizard are written to `.env.dnstap2` with mode `0600`; setup runs and the standalone scripts both pick them up from there.

See `config.example.toml` for the annotated schema. The fields you almost certainly want to set:

| | |
|---|---|
| `infoblox.host` | grid master IP — pre-filled with `192.168.1.224` |
| `infoblox.username` | WAPI user — pre-filled with `admin` |
| `INFOBLOX_PASSWORD` env var | WAPI password — **do not commit** |
| `receiver.advertised_host` | IP of THIS host as reachable from the grid master |
| `splunk.enabled` / `SPLUNK_HEC_TOKEN` | flip to `true` and set the token to enable HEC sink |

### Splunk: two feeds, two formats

Events reach Splunk in the **same syslog format InfoBlox emits with native DNS
query/response logging** (sourcetype `infoblox:dns`, via Vector HEC), so
dashboards built for InfoBlox syslog need no rewrite. A parallel **flat-json**
feed (sourcetype `dnscollector:json`, via DNS-collector → raw TCP) provides
machine-friendly fields. Both can run at once; see the table in
[QUICKSTART.md](QUICKSTART.md#splunk-two-feeds-two-formats). Ready-made
dashboards ship in [`splunk/`](splunk/) (catalog: [`splunk/README.md`](splunk/README.md)):
`dns_dnstap_overview.xml` for the flat-json `dns_dnstap` index, plus
`dns_dnstap_ab_overview.xml` and `dns_dnstap_filterable.xml` for the POC `mi_dhcp`
text path — the latter pair compare/filter **Vector vs DNS-collector** on the
`source` field and parse the NIOS line with search-time `rex` (no indexer config).

**Optional system + service health (SNMP).** dnstap can't tell you whether a
member is healthy or its DNS service is up. `scripts/poc_health_snmp.py` polls the
InfoBlox enterprise MIB (`.7779`) for CPU/mem/swap %, **per-service status**
(dns, dhcp, ntp, cache-accel, threat-protection, replication, raid, fans, …), CPU
temperature and replication/HA, and ships Splunk `key=value` lines to the same
`mi_dhcp` index (`sourcetype=infoblox:health`). A **targets file** polls the whole
fleet of dnstap-sending members; `scripts/install_health_snmp.sh` runs it as a
systemd service; `infoblox_system_health.xml` renders it like the InfoBlox Grid
Manager "System" panel. See [QUICKSTART.md](QUICKSTART.md#optional-infoblox-system-health-via-snmp).

## Verifying it works

```bash
# 1. Vector is up and exposing metrics
curl -sf http://localhost:9598/metrics > /dev/null && echo "vector OK"

# 2. Prometheus is scraping Vector
curl -s http://localhost:9090/api/v1/targets | grep '"health":"up"'

# 3. End-to-end frame count
python scripts/test_dnstap_flow.py --config config.toml --seconds 30

# 4. JSONL archive is filling up
sudo tail -f /var/log/dnstap/events.jsonl
```

## Running on macOS (lab only)

macOS works for ad-hoc lab testing without systemd:

```bash
./scripts/setup.sh --no-systemd --skip-install   # render configs only
# then in separate terminals:
vector --config $(grep config_path config.toml | head -1 | cut -d'"' -f2)
prometheus --config.file $(grep -A1 '\[prometheus\]' config.toml | grep config_path | cut -d'"' -f2)
```

You can install Vector and Prometheus via Homebrew (`brew install vectordotdev/brew/vector prometheus`) instead of letting `install_vector.py` / `install_prometheus.py` drop binaries into `/usr/local/bin`.

## Tests

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest
```

## License

MIT
