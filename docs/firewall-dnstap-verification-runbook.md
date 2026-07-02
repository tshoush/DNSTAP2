# Firewall + dnstap verification runbook — NIOS (AWS) → remote collector

Scenario: Infoblox NIOS 9.x member (vNIOS on AWS, WAPI 2.13.7) at **10.10.1.200**
must deliver dnstap (Frame Streams over **TCP 6000**) to the receiver at **.234**.
The firewall team reports the port open; this runbook proves (or disproves) it
layer by layer, and then proves dnstap data actually flows.

Sources: Infoblox NIOS 9.0 docs (CLI, Traffic Capture Tool), farsightsec/fstrm
protocol, Infoblox community, plus behavior verified live in our lab (192.168.1.x).
Items the research could NOT verify are marked **[unverified — check on the box]**.

---

## Test 0 — Preconditions (before blaming any firewall)

1. **License gate**: dnstap on NIOS is only available on members running
   **DNS Cache Acceleration or DNS Infrastructure Protection** (vNIOS-for-AWS
   9.0.1+; medium confidence — 2-1 verification vote; IB-FLEX on AWS reportedly
   does *not* support DCA). On the NIOS CLI: `show license`. No license → dnstap
   simply won't emit, regardless of firewall.
2. **Config present** — two independent views, they must agree:
   - NIOS CLI: `show dnstap-status` → receiver IP/port and query/response
     toggles (this is *configuration state only*, not live health).
   - WAPI (from any admin host):
     ```bash
     curl -sk -u <admin> "https://<grid-master>/wapi/v2.13.7/member:dns?host_name=<member-fqdn>&_return_fields=enable_dnstap_queries,enable_dnstap_responses,use_dnstap_setting,dnstap_setting"
     ```
     Expect `dnstap_receiver_address = <.234>`, `dnstap_receiver_port = 6000`,
     both enables `true`, `use_dnstap_setting = true`.
3. dnstap config changes need a **DNS service restart** to take effect — the
   frame stream only dials out after the restart.

## Test 1 — Receiver readiness on .234

```bash
systemctl is-active vector
ss -ltn 'sport = :6000'                      # listener up?
firewall-cmd --list-all                      # host firewall allows 6000/tcp from 10.10.1.200?
curl -s http://localhost:9598/metrics | grep dnstap_   # baseline counters
```

Lab-learned hard rule: make sure the Vector config has **no Loki sink pointing
at a dead endpoint** (or that it has `buffer.when_full = "drop_newest"`). A dead
optional sink backpressure-stalled the entire pipeline in our lab while every
service showed "active".

## Test 2 — Cheap path probes (know what they do and don't prove)

- NIOS restricted CLI has `ping` and `traceroute`/`tracepath`. These are
  **ICMP-only**: success proves L3 reachability; failure proves nothing (ICMP is
  commonly blocked while TCP 6000 is open) — and neither tests port 6000.
- **Telnet/netcat from the NIOS CLI: unresolved.** The research could not verify
  a complete NIOS 9.x CLI command inventory. Run `help` on the appliance and
  look for any TCP connect test. If absent (likely), the dnstap dial-out itself
  is your connect test — that's Test 4.
- If you have *any* host in the same subnet/security zone as 10.10.1.200 (jump
  box, another VM behind the same firewall path): `nc -vz <.234> 6000`. Useful
  smoke test, but firewall rules are usually source-IP-scoped — only traffic
  actually sourced from 10.10.1.200 proves the rule.

## Test 3 — AWS-side egress (the part the corporate firewall team can't see)

Even with the corporate firewall open, the vNIOS instance itself can be blocked:

1. **Security group** on the vNIOS ENI: SGs allow all egress by default, but if
   yours is restricted, note that Infoblox's documented vNIOS SG table contains
   **no dnstap rule** — add outbound TCP 6000 → .234 explicitly.
2. **Subnet NACLs are stateless** — you need BOTH directions:
   - outbound: TCP dst port 6000 to .234
   - inbound: TCP src port 6000 from .234 to ephemeral ports 1024–65535
3. **Routing**: route table / TGW / VPN must carry the .234 prefix from the
   vNIOS subnet.

## Test 4 — The definitive test: enable dnstap and watch both ends at once

**Receiver side** (start first, leave running):

```bash
tcpdump -ni <iface> host 10.10.1.200 and tcp port 6000 -X
```

**NIOS side** (simultaneously): the CLI packet capture is a wrapped tcpdump that
accepts standard BPF filters:

```
set traffic_capture on          # filter on host <.234> (see Traffic Capture Tool docs)
show traffic_capture
```

Retrieve the `.cap` via Grid Manager (member → Traffic Capture download) and open
in Wireshark. Then enable dnstap (WAPI PUT or Grid UI) and restart DNS.

**Interpret the receiver tcpdump — this table localizes the fault:**

| Observation on .234 | Verdict | Owner |
|---|---|---|
| No packets at all from 10.10.1.200 (but NIOS capture shows SYNs leaving) | Firewall/AWS silently dropping | firewall team / AWS SG-NACL (Test 3) |
| No packets, and NIOS capture shows no SYNs either | NIOS never dialing — config/license/restart missing | DDI (Test 0) |
| SYN arrives, receiver sends RST | Port reached but closed — Vector down / wrong port | receiver admin (Test 1) |
| SYN arrives, no SYN-ACK sent | Receiver *host* firewall (firewalld/iptables INPUT) | receiver admin |
| SYN arrives, RST comes from an intermediate hop / wrong TTL | Firewall actively rejecting (vs silent drop) | firewall team |
| TCP established, then payloads containing ASCII `protobuf:dnstap.Dnstap` | fstrm handshake in progress — healthy | — |
| TCP established but no fstrm exchange / immediate close | Application-layer mismatch (wrong service on 6000, TLS vs plaintext, non-fstrm listener) | receiver admin |

fstrm handshake detail: control frames start with a 4-byte `00 00 00 00` escape +
big-endian length + control type (`READY=0x04` from NIOS, `ACCEPT=0x01` from the
collector, then `START=0x02`), carrying the content-type string
`protobuf:dnstap.Dnstap` — visible in `tcpdump -X`. (Byte-offset filters on the
escape are only reliable on the initial segment-aligned handshake; use
`tshark` with reassembly for anything deeper.)

**NIOS live health check** — the single most useful on-box indicator:

```
show dnstap-stats     # "Duration connected(s)" > 0 and growing = session up
                      # "Total bytes sent" increasing = frames leaving
```

(Field semantics — whether duration resets on reconnect — are undocumented;
treat as indicative. `show dnstap-status` remains config-only.)

## Test 5 — End-to-end data proof (marked queries)

```bash
MARK="fwtest-$(date +%s)"
for n in $(seq 1 20); do dig @10.10.1.200 "${MARK}-${n}.example.com" +tries=1 +time=2 >/dev/null; done
```

Then on .234 (expect **exactly 2× the query count** — query + response):

```bash
curl -s http://localhost:9598/metrics | grep -E 'sent_events_total.*(dnstap_in|splunk|jsonl)'
sudo grep -c "$MARK" /var/log/dnstap/events.jsonl
```

And in Splunk: `index=<idx> "fwtest-<epoch>"` → count = 2× queries.
Expect events to arrive in **bursts/waves** — NIOS ships dnstap in short batches
(observed repeatedly in our lab; counts stay exact, timing is lumpy).

## Test 6 — Resilience checks (do this before calling it production-ready)

1. **Outage behavior**: stop Vector on .234 for 2 minutes, send 20 marked
   queries, restart Vector. NIOS most likely **drops** dnstap frames while the
   collector is unreachable (BIND's fstrm is lossy by design; **[unverified for
   NIOS — measure it here]**). Record whether the 20 queries' events ever arrive.
2. **Reconnect**: after the restart, confirm `show dnstap-stats` shows the
   session re-established without a DNS service restart, and new queries flow.
3. **Soak**: leave overnight; counters monotonic, no reconnect churn in Vector
   logs, Splunk event rate matches expectations.

## Known unknowns (flagged by adversarial verification — don't assert these)

- Whether the NIOS 9.x restricted CLI includes any direct TCP connect test
  (`help` on the live box is the authority).
- The exact syslog/named messages NIOS emits on dnstap connect success/refusal/
  timeout — watch the member syslog during Test 4 and record what you see.
- NIOS buffering vs dropping while the collector is down, and reconnect/backoff
  timing (Test 6 measures it).
- The DCA/DNS-Infrastructure-Protection licensing gate as it applies to your
  exact vNIOS model + NIOS point release — confirm with `show license` /
  Infoblox support.

Key sources: docs.infoblox.com NIOS 9.0 (CLI command pages; "Using the Traffic
Capture Tool"), github.com/farsightsec/fstrm (control frame protocol),
weberblog.net CLI troubleshooting notes, Infoblox community (grid connectivity
testing), Infoblox vNIOS-for-AWS deployment guide (SG table, Nov 2022 vintage).
