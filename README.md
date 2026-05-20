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
│   ├── setup.sh                # one-shot orchestrator
│   ├── lib/                    # shared helpers (config, WAPI client, platform)
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

## Prerequisites

- Python **3.11+**
- Linux with **systemd** (recommended) or macOS (foreground mode)
- Network reachability from this host to the InfoBlox grid master (TCP/443) and *from* the grid master back to this host on the receiver port (default `6000/tcp`)
- `sudo` for writing systemd units and `/etc/` config files (or override `install_prefix` in `config.toml` to a user-owned dir)

## Quick start

The short version — full walkthrough in [QUICKSTART.md](QUICKSTART.md):

```bash
git clone https://github.com/tshoush/DNSTAP2.git
cd DNSTAP2

cp config.example.toml config.toml
$EDITOR config.toml            # set receiver.advertised_host to this machine's IP

export INFOBLOX_PASSWORD=infoblox   # do not commit the password

./scripts/setup.sh                 # dry-run end-to-end
./scripts/setup.sh --apply         # actually push the InfoBlox dnstap config
```

Verify:

```bash
python scripts/test_dnstap_flow.py --config config.toml
curl -s http://localhost:9598/metrics | grep dnstap_
open  http://localhost:9090
```

## Configuration

Everything is driven by `config.toml`. See `config.example.toml` for the annotated schema. The fields you almost certainly want to set:

| | |
|---|---|
| `infoblox.host` | grid master IP — pre-filled with `192.168.1.224` |
| `infoblox.username` | WAPI user — pre-filled with `admin` |
| `INFOBLOX_PASSWORD` env var | WAPI password — **do not commit** |
| `receiver.advertised_host` | IP of THIS host as reachable from the grid master |
| `splunk.enabled` / `SPLUNK_HEC_TOKEN` | flip to `true` and set the token to enable HEC sink |

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
