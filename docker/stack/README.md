# docker/stack — full DNSTAP2 observability stack (Docker Compose)

Stands up the **entire receiver + monitoring stack** in containers:

```
InfoBlox / DNS server          ── dnstap frames ──▶   :6001  DNS-collector
   (EXTERNAL — not in stack)                                   │  ├─ metrics :9599 ─▶ Prometheus :9090 ─▶ Grafana :3000
                                                               │  └─ events (flat-json) ─────────────▶ Loki :3100 ─▶ Grafana
```

Everything **except InfoBlox and the DNS server** is here. Those stay external
and simply dial dnstap frames into port **6001** on the host running this stack.

This is the container equivalent of the native installers
(`scripts/install_dnscollector_receiver.sh`, `install_prometheus.*`,
`install_grafana.sh`, `install_loki.sh`). Because everything runs in containers,
the host only needs Docker + Compose — **no glibc 2.17 / systemd 219 concerns**,
so it runs the same on RHEL 7.9, RHEL 9, macOS, or WSL2.

## Services

| Service | Image | Host port | Purpose |
|---|---|---|---|
| `dnscollector` | built from pinned release (`Dockerfile.dnscollector`) | `6001` (dnstap), `9599` (metrics) | Receives dnstap frame-streams; exports metrics; ships events to Loki + a JSONL archive. |
| `prometheus` | `prom/prometheus:v2.53.0` | `9090` | Scrapes `dnscollector:9599`. |
| `loki` | `grafana/loki:2.9.8` | `3100` | Stores DNS event logs (flat-json from DNS-collector). |
| `grafana` | `grafana/grafana:10.4.2` | `3000` | Dashboards; Prometheus + Loki datasources and the DNS-collector dashboard are auto-provisioned. |

## Quick start

```bash
cd docker/stack
docker compose up -d --build      # first run builds the dnscollector image

# Grafana:    http://<host>:3000   (admin / admin; anonymous Viewer enabled)
# Prometheus: http://<host>:9090   (Status > Targets — dnscollector should be UP)
# dnstap in:  <host>:6001          <- point the NIOS member's dnstap receiver here
```

Then in InfoBlox, set the member's dnstap receiver to `<this-host>:6001`. The
"DNS-collector Overview" dashboard (DNS folder in Grafana) populates as frames arrive.

## Smoke-test without InfoBlox

Use the repo's synthetic generator from the host to fire frames at `:6001`:

```bash
# from the repo root, on the host
python scripts/dnstap_synth.py --tcp 127.0.0.1:6001
```

Metrics should appear at `http://<host>:9090` (query `dnscollector_*`) and the
Grafana dashboard should start moving.

## Common operations

```bash
docker compose ps                 # status
docker compose logs -f dnscollector
docker compose down               # stop (keeps volumes/data)
docker compose down -v            # stop AND wipe Prometheus/Loki/Grafana/archive data
```

## What's configured where

| File | Role |
|---|---|
| `docker-compose.yml` | service topology, ports, volumes, the `dnstap` bridge network |
| `Dockerfile.dnscollector` | builds DNS-collector from the pinned `v2.2.3` release tarball |
| `dnscollector/config.yml` | dnstap input `:6001`, outputs → Prometheus `:9599`, Loki, JSONL archive |
| `prometheus/prometheus.yml` | scrape job for `dnscollector:9599` |
| `grafana/provisioning/datasources/` | Prometheus (`uid: prometheus`) + Loki (`uid: loki`) |
| `grafana/provisioning/dashboards/` | provider + `json/dnscollector-overview.json` |

## Notes & caveats

- **Inbound reachability.** InfoBlox must be able to reach `<host>:6001`. On a
  cloud/RHEL host open the firewall (`firewall-cmd --add-port=6001/tcp
  --permanent && firewall-cmd --reload`). On **WSL2**, the grid master can't
  address the WSL VM directly — only the Windows host — so use mirrored
  networking or `netsh portproxy` (see the repo-root `QUICKSTART.md`).
- **Apple Silicon.** The DNS-collector image builds for `amd64` by default. On
  arm64 build with `docker compose build --build-arg TARGETARCH=arm64` (or use
  buildx), the other images are multi-arch.
- **Versions** are pinned to match the native installers (DNS-collector 2.2.3,
  Prometheus 2.53.0, Grafana 10.4.2). Grafana 10.4.x is the last line supporting
  glibc 2.17 natively — irrelevant inside a container, kept for parity.
- **Vector vs DNS-collector.** This stack uses **DNS-collector** as the receiver
  (`:6001`, `dnscollector_*`), matching `grafana/dashboards/dnscollector-overview.json`.
  Vector (`:6000`, `dnstap_*`) is the other supported receiver; it's not in this
  compose file by design (see `../../CLAUDE.md`).
- **Lab credentials.** Grafana is `admin/admin` with anonymous viewer enabled —
  fine for a POC, change before anything resembling production.
