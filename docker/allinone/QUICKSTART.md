# All-in-one QUICKSTART — single-container DNSTAP2 stack

Five minutes to a running single container with DNS-collector + Prometheus +
Loki + Grafana. For the multi-container version see `../stack/QUICKSTART.md`.

## 0. Prerequisites

- Docker Engine or Docker Desktop. (No Compose needed — this is one image.)
- Build from the **repo root** so the build context is `docker/allinone`.

```bash
cd /home/tmsho448/DNSTAP2     # repo root
```

## 1. Build

```bash
docker build -t dnstap2-allinone docker/allinone
# Apple Silicon: docker build --build-arg TARGETARCH=arm64 -t dnstap2-allinone docker/allinone
```

First build downloads four upstream binaries (DNS-collector, Prometheus, Loki,
Grafana) — give it a minute.

## 2. Run

```bash
docker run -d --name dnstap2 \
    -p 6001:6001 -p 3000:3000 -p 9090:9090 -p 3100:3100 \
    dnstap2-allinone

docker logs -f dnstap2        # Ctrl-C to stop tailing; container keeps running
```

You should see Loki, Prometheus, DNS-collector, and Grafana each log a startup
line.

## 3. Verify the services are up

```bash
curl -s http://localhost:9599/metrics | head        # DNS-collector exporter
curl -s http://localhost:9090/-/ready               # Prometheus -> "Ready"
curl -s http://localhost:3100/ready                 # Loki        -> "ready"
curl -s http://localhost:3000/api/health            # Grafana     -> JSON, "database":"ok"
```

Open Grafana at **http://localhost:3000** (admin/admin). Under **Dashboards →
DNS** you'll find **DNS-collector Overview**. Under **Connections → Data
sources** Prometheus and Loki are already provisioned.

## 4. Smoke-test with synthetic dnstap (no InfoBlox needed)

From the host, fire synthetic frames at the receiver port:

```bash
python scripts/dnstap_synth.py --tcp 127.0.0.1:6001
```

Within ~15s (one scrape interval) the **DNS-collector Overview** dashboard
starts moving, and `dnscollector_*` series appear in Prometheus
(http://localhost:9090, try `Status → Targets` — the `dnscollector` job should
be **UP**).

## 5. Point InfoBlox at it

Set the NIOS member's dnstap receiver to `<this-host>:6001`
(`member:dns` → dnstap receiver address/port). Ensure the host firewall allows
inbound `6001/tcp`; on WSL2 use mirrored networking or `netsh portproxy`
(repo-root `QUICKSTART.md`).

## 6. Lifecycle

```bash
docker stop dnstap2          # stop
docker start dnstap2         # start again
docker rm -f dnstap2         # remove (data is lost unless you mounted volumes)
```

To keep data across `docker rm`, add the `-v` volume mounts shown in
`README.md`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Dashboard empty | Is traffic flowing? Run the synthetic test (step 4). Confirm the `dnscollector` Prometheus target is UP. |
| Grafana 500 / no datasources | `docker logs dnstap2` for the grafana lines; provisioning is read from `/etc/grafana/provisioning`. |
| InfoBlox can't connect | Host firewall on `6001/tcp`; on WSL2 see the networking note above. |
| One service died | `docker exec dnstap2 supervisorctl status` — supervisord auto-restarts crashed programs. |
