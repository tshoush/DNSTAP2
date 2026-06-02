# Firewall Ports — DNS Telemetry Pipeline

Prepared for the security team. Lists the network connections that must be
permitted for the DNS dnstap telemetry pipeline and its observability tools.

Roles are used instead of IP addresses so this stays valid as hosts change —
substitute your actual hostnames/IPs when writing the firewall policy.

## Roles

| Role | What it is |
|---|---|
| **DNS Server** | The DNS appliance (InfoBlox NIOS member) that emits the dnstap telemetry stream. |
| **Telemetry Host** | The single box that runs **DNSCollector** and all the observability tools below. |

> **Everything except the DNS Server runs on the Telemetry Host.** DNSCollector,
> Prometheus, Grafana, Loki, and Alertmanager are all co-located on that one box
> and talk to each other over loopback (`127.0.0.1`) — those internal hops need
> **no firewall rules**. Only two kinds of connection cross the network:
> (1) the DNS Server → DNSCollector telemetry stream, and (2) operators/users →
> the tools' web UIs on the Telemetry Host.

---

## 1. DNS Server → DNSCollector  (the telemetry stream)

This is the core data path. The DNS Server **initiates** the connection to the
Telemetry Host and pushes its dnstap stream over it. It is **one-way**: the DNS
Server connects out, the Telemetry Host only listens. No reverse connection is
needed.

| Source | Destination | Proto / Port | Purpose |
|---|---|---|---|
| **DNS Server** | **Telemetry Host** | TCP **6001** | dnstap stream → DNSCollector (Frame Streams / fstrm) |

**Required rule:** allow `DNS Server → Telemetry Host : TCP 6001` (inbound to the
Telemetry Host). That single rule is sufficient for the entire data path.

> *Parallel/alternate receiver:* a second receiver (**Vector**) can run on the
> same host on **TCP 6000** for A/B or fallback. Open `6000` as well **only if**
> you point a DNS Server at Vector. If you only run DNSCollector, leave 6000
> closed.

---

## 2. Operators / Users → Telemetry Host  (the tools)

So people and other tools can reach the dashboards and APIs on the Telemetry
Host. Open only what you actually need to reach from another machine — the rest
can stay loopback-only.

| Source | Destination | Proto / Port | Tool / Purpose | Recommended exposure |
|---|---|---|---|---|
| Admin browser | **Telemetry Host** | TCP **3000** | **Grafana** dashboards (UI) | LAN / users — **open** |
| Admin / operator | **Telemetry Host** | TCP **9090** | **Prometheus** UI & query API | Optional — open only if queried remotely |
| Admin / operator | **Telemetry Host** | TCP **9093** | **Alertmanager** UI & API | Optional — usually loopback-only |
| Admin / operator | **Telemetry Host** | TCP **3100** | **Loki** log query/push API | Optional — usually loopback-only |
| Admin | **Telemetry Host** | TCP **22** | SSH management | LAN / admin — **open** |

**Typically need to be network-reachable:** **3000** (Grafana) and **22** (SSH).
Everything else in this table is consumed locally by Grafana/Prometheus on the
same box and can stay closed at the firewall.

---

## 3. Internal (same-box) connections — no firewall rules needed

Listed for completeness. These all stay on `127.0.0.1` on the Telemetry Host, so
the firewall never sees them. Do **not** open these to the network.

| From (on Telemetry Host) | To (on Telemetry Host) | Proto / Port | Purpose |
|---|---|---|---|
| Prometheus | DNSCollector | TCP 9599 | Scrape DNSCollector metrics (`dnscollector_*`) |
| Prometheus | Vector *(if run)* | TCP 9598 | Scrape Vector metrics (`dnstap_*`) |
| Grafana | Prometheus | TCP 9090 | Query metrics for dashboards |
| Grafana | Loki | TCP 3100 | Query logs for dashboards |
| DNSCollector / Vector | Loki | TCP 3100 | Push log lines |
| Prometheus | Alertmanager | TCP 9093 | Send alerts |
| Loki (internal) | Loki (internal) | TCP 9096 | Loki gRPC (internal only) |
| DNSCollector / Vector | rsyslog | UDP 514 | Optional syslog/SIEM forward (loopback only) |

---

## Summary — minimal firewall policy

| # | Rule | Why |
|---|---|---|
| 1 | `DNS Server → Telemetry Host : TCP 6001` | dnstap telemetry stream (the data path) |
| 2 | `Admin/Users → Telemetry Host : TCP 3000` | Grafana dashboards |
| 3 | `Admin → Telemetry Host : TCP 22` | SSH management |

Open Prometheus (9090), Alertmanager (9093), Loki (3100), and Vector (6000) only
if you specifically need them reachable from another host; otherwise keep them
loopback-only.

## Notes for the security team

- **The telemetry stream is one-way** (DNS Server → Telemetry Host). No reverse
  path is required; a stateful rule on TCP 6001 in that direction is enough.
- **dnstap payloads carry full DNS query content** (client identifiers, queried
  domain names). Treat the Telemetry Host — and Loki's log store / on-disk
  archives on it — as sensitive-data systems for access control and retention.
- **Grafana** ships with default credentials and may have anonymous viewing
  enabled. Change the admin password and review anonymous access before exposing
  port 3000 beyond a trusted network.
