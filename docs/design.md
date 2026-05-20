# Design notes

## Why this exists

A Phase-1 lab artifact for the InfoBlox dnstap proposal (see the `ClaudePreso` repo). We want a very small, very readable thing that:

- Proves InfoBlox NIOS members actually emit dnstap frames as advertised.
- Lets us A/B benchmark resolver CPU with dnstap on vs query-logging on.
- Demonstrates end-to-end ingest into Splunk HEC with structured fields.
- Stays small enough that an on-call engineer can read it in an hour.

This is **not** a production collector. The InfoBlox proposal explicitly recommends a real, supported collector for production rollout.

## Layering

```
+-------------------------------------------+
| CLI (cli.py)                              |   thin argparse layer
+-------------------------------------------+
| Collector (collector.py)                  |   socket accept loop
+-------------------------------------------+
| Frame Streams reader (framestream.py)     |   stdlib only, no protobuf
+-------------------------------------------+
| Decoder (decoder.py)                      |   STUB — replace with real dnstap.proto
+-------------------------------------------+
| Sinks (sinks/{stdout,jsonl,splunk_hec})   |   pluggable output
+-------------------------------------------+
```

Each layer is independently testable. The framing layer in particular is pure-Python and stdlib-only — easy to unit test against synthetic byte streams, which is what `tests/test_framestream.py` does.

## What's deliberately not here

- **Bidirectional Frame Streams handshakes.** DNS servers send unidirectional content streams by default; we only support that.
- **TLS / mutual auth.** Add a TLS termination layer (e.g. nginx, stunnel, or `ssl.SSLContext.wrap_socket`) in front for any non-lab use.
- **Async / multi-connection scaling.** The collector is single-threaded for clarity. For real load: hand each accepted connection to a worker thread, or rewrite on asyncio.
- **The real protobuf decoder.** Wiring this in is the next concrete task; see `decoder.py`.

## Splunk HEC sink notes

- Each event is one HEC request — fine for lab volumes, terrible at line rate. Batching is the obvious next step: collect events into a list, flush every N events or every M milliseconds.
- The `host` field is populated from the decoded `query_address` (once the real decoder is in place); until then it will be `None`.
- For pilot dashboards: a Splunk index `dns_dnstap` with sourcetype `dnstap:json` lines up with the field-extraction-free path (Splunk auto-parses JSON sourcetype).

## Next concrete tasks (in order)

1. Add the real protobuf decoder per `decoder.py` docstring.
2. Add batching to `splunk_hec.py`.
3. Add a benchmark harness: spin up named/Unbound in a container, fire `dnsperf`, record dnstap event rate vs syslog query-log event rate on the same workload.
4. Document the InfoBlox NIOS-specific configuration steps once verified against the actual build.
