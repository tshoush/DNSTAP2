# docker/allinone — single-container DNSTAP2 stack

One Docker **image** containing **all four services** — DNS-collector,
Prometheus, Loki, and Grafana — supervised by `supervisord`. Everything except
InfoBlox and the DNS server, which stay external and dial dnstap frames into
port **6001**.

```
InfoBlox / DNS server ──dnstap──▶ :6001  ┌─────────── one container ───────────┐
   (EXTERNAL)                            │ dnscollector → :9599 → prometheus    │
                                         │      └─ events → loki :3100          │
                                         │ grafana :3000 ◀ prometheus :9090     │
                                         │                ◀ loki :3100          │
                                         └──────────────────────────────────────┘
```

## When to use this vs `../stack`

| | `allinone` (this) | `../stack` (compose) |
|---|---|---|
| Containers | **1** (supervisord runs 4 processes) | 4 (one per service) |
| Ship/run | a single image to `docker run` | `docker compose up` |
| Upgrade one service | rebuild the whole image | restart/upgrade that service alone |
| Best for | demos, air-gapped handoff, "just give me one thing to run" | normal ops, independent lifecycle |

Both receive on `:6001` and expose Grafana `:3000` / Prometheus `:9090` /
Loki `:3100` identically — pick by operational preference.

## Build & run

```bash
# from the repo root
docker build -t dnstap2-allinone docker/allinone

docker run -d --name dnstap2 \
    -p 6001:6001 \   # dnstap in  <- point InfoBlox here
    -p 3000:3000 \   # Grafana    (admin/admin, anon viewer)
    -p 9090:9090 \   # Prometheus
    -p 3100:3100 \   # Loki
    dnstap2-allinone

docker logs -f dnstap2          # watch all four services start
```

Apple Silicon: add `--build-arg TARGETARCH=arm64` to the build.

Persist data across `docker rm` by mounting volumes:

```bash
docker run -d --name dnstap2 \
    -p 6001:6001 -p 3000:3000 -p 9090:9090 -p 3100:3100 \
    -v dnstap2-grafana:/var/lib/grafana \
    -v dnstap2-prometheus:/var/lib/prometheus \
    -v dnstap2-loki:/var/lib/loki \
    -v dnstap2-archive:/var/log/dnscollector \
    dnstap2-allinone
```

## What's inside

| Component | Version | Listens on | Notes |
|---|---|---|---|
| DNS-collector | 2.2.3 | `:6001` dnstap, `:9599` metrics | receiver; ships to Prometheus + Loki + JSONL archive; latency transform on (`dnstap.latency`); optional Splunk flat-json feed (commented `splunkout` block in config) |
| Prometheus | 2.53.0 | `:9090` | scrapes `localhost:9599` |
| Loki | 2.9.8 | `:3100` | DNS event logs (filesystem storage) |
| Grafana | 10.4.2 | `:3000` | Prometheus + Loki datasources + DNS-collector dashboard auto-provisioned |

All four are launched by `supervisord` (`supervisord.conf`) and log to the
container's stdout, so `docker logs dnstap2` shows everything in one place.
`tini` is PID 1 to reap zombies.

## Config layout

| Path in repo | Mounted/baked at | Role |
|---|---|---|
| `Dockerfile` | — | multi-stage: fetch pinned binaries → supervised runtime |
| `supervisord.conf` | `/etc/supervisor/conf.d/dnstap2.conf` | the four program definitions |
| `config/dnscollector/config.yml` | `/etc/dnscollector/config.yml` | dnstap in `:6001`; outputs to localhost Prometheus/Loki + archive |
| `config/prometheus/prometheus.yml` | `/etc/prometheus/prometheus.yml` | scrape `localhost:9599` |
| `config/loki/loki-config.yml` | `/etc/loki/loki-config.yml` | single-binary filesystem Loki |
| `config/grafana/custom.ini` | `/etc/grafana/custom.ini` | paths, port, lab admin creds |
| `config/grafana/provisioning/` | `/etc/grafana/provisioning/` | datasources + dashboard provider + JSON |

## Caveats

- **Single failure domain.** All four processes share one container; if it
  dies, everything goes. `supervisord` restarts individual crashed processes,
  but for independent lifecycle use `../stack`.
- **Inbound reachability.** InfoBlox must reach `<host>:6001` — open the
  firewall on RHEL; on WSL2 use mirrored networking / `netsh portproxy` (see the
  repo-root `QUICKSTART.md`).
- **Lab credentials.** Grafana `admin/admin` with anonymous viewer — change
  before anything production-like.
- **Receiver is DNS-collector** (`:6001`, `dnscollector_*`), matching the
  shipped dashboard. Vector is the other supported receiver and is intentionally
  not bundled here (see `../../CLAUDE.md`).

See `QUICKSTART.md` for the 5-minute path including a synthetic-traffic test.
