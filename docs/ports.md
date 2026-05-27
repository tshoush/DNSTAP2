# Port Matrix — DNSTAP2 Telemetry Lab

Reference for the security team. Lists every port used across the dnstap
telemetry pipeline, the observability stack, and the NIOS appliances.

- **Lab subnet:** `192.168.1.0/24` (network container `192.168.0.0/16`). Swap in
  production subnets/hostnames when formalizing firewall policy.
- **Hosts:**
  - `192.168.1.224` — NIOS Grid Master
  - `192.168.1.222` — NIOS DNS member (dnstap source)
  - `192.168.1.50` — Receiver host (RHEL 7.9): Vector, DNS-collector, Prometheus, Grafana, Loki, Alertmanager, rsyslog
- **Status legend:** `verified` = observed live on the host (`ss`/`firewall-cmd`);
  `standard` = documented Infoblox default, not probed on the appliance — please
  cross-check against Infoblox's official port reference.

Companion machine-readable file: [`ports.csv`](ports.csv).

## 1. dnstap telemetry pipeline (core data path)

| Source | Destination | Proto/Port | Purpose | Notes | Status |
|---|---|---|---|---|---|
| NIOS member `192.168.1.222` | Receiver `192.168.1.50` | TCP 6000 | dnstap stream → Vector (Frame Streams) | Active receiver is whichever the member targets | verified |
| NIOS member `192.168.1.222` | Receiver `192.168.1.50` | TCP 6001 | dnstap stream → DNS-collector (Frame Streams) | Alternative receiver, runs in parallel | verified |

## 2. Receiver host `192.168.1.50` — observability stack

| Source | Destination | Proto/Port | Purpose | Exposure | Status |
|---|---|---|---|---|---|
| Admin browser | `.50` | TCP 3000 | Grafana UI | LAN-open (firewalld) | verified |
| Prometheus (local) | `.50` | TCP 9598 | Scrape Vector metrics (`dnstap_*`) | LAN-open; only needs localhost | verified |
| Prometheus (local) | `.50` | TCP 9599 | Scrape DNS-collector metrics (`dnscollector_*`) | LAN-open; only needs localhost | verified |
| Grafana / operator | `.50` | TCP 9090 | Prometheus API/UI | LAN-open; could be localhost | verified |
| Vector / DNS-collector / Grafana | `.50` | TCP 3100 | Loki push + query | LAN-open; used via 127.0.0.1 | verified |
| Prometheus / operator | `.50` | TCP 9093 | Alertmanager API/UI | LAN-open; used via 127.0.0.1 | verified |
| Vector / DNS-collector | `.50` | UDP 514 | syslog/SIEM forward → rsyslog | Binds all-ifaces but firewalld-blocked; reached only via 127.0.0.1 | verified |
| Admin | `.50` | TCP 22 | SSH management | LAN-open (ssh service) | verified |

**firewalld currently allows inbound:** `6000, 6001, 9090, 9598, 9599, 3000, 3100, 9093 /tcp` + `ssh`. `514/udp` is **not** opened (loopback-only in practice).

## 3. NIOS appliances — DNS service, management & grid

*Standard Infoblox NIOS defaults — cross-check against Infoblox's official port reference.*

| Source | Destination | Proto/Port | Purpose | Status |
|---|---|---|---|---|
| DNS clients | `.222` / `.224` | UDP 53 / TCP 53 | DNS query/response (TCP for AXFR/large) | standard |
| Admin | Grid Master `.224` | TCP 443 | GUI / WAPI / Grid Manager (HTTPS) | standard |
| Admin | `.222` / `.224` | TCP 22 | SSH / remote console | standard |
| Member `.222` ↔ Grid Master `.224` | — | UDP 1194 | Grid VPN tunnel (member↔GM, default) | standard |
| Member `.222` ↔ Grid Master `.224` | — | TCP 2114 | Grid communication (object distribution) | standard |
| Member `.222` ↔ Grid Master `.224` | — | UDP 123 | NTP grid time sync | standard |
| Monitoring (optional) | `.222` / `.224` | UDP 161 / 162 | SNMP poll / traps | standard |

## Hardening recommendations

- **Tighten the internal stack to loopback.** `9598, 9599, 9090, 3100, 9093` only
  ever need `127.0.0.1` (Prometheus scrapes locally; Loki/Alertmanager are
  co-located). Remove them from firewalld and/or bind to `127.0.0.1`. Only
  **6000/6001** (inbound dnstap from `.222`), **3000** (Grafana UI), and **22**
  (SSH) need to be network-reachable.
- **dnstap is one-way, member→receiver.** `.222` initiates the TCP connection to
  `.50:6000/6001`; no reverse path is needed. A rule allowing only
  `192.168.1.222 → 192.168.1.50:6000,6001/tcp` is sufficient.
- **Grafana** currently has anonymous Viewer enabled and `admin/admin` — change
  the admin password and consider disabling anonymous access before exposing it
  beyond the lab.
- **dnstap payloads carry full DNS query content** (client IPs, qnames). Treat the
  `.50` receiver, its `:3100` Loki store, and `/var/log/dnstap*` as
  sensitive-data systems for access-control and retention purposes.
