# dnstap2

A small **dnstap collector and parser** in Python — receives Frame Streams from a DNS server (InfoBlox NIOS, BIND, Unbound, Knot) over a UNIX socket or TCP, decodes the dnstap payloads, and forwards structured events to a sink (stdout, JSON file, or Splunk HEC).

Built as a **Phase-1 lab artifact** for the InfoBlox dnstap proposal. The goal here is not a production collector — it is a small, readable reference implementation we can use to:

1. Validate that our InfoBlox DNS members actually emit dnstap frames as expected.
2. Benchmark resolver overhead with dnstap on vs off.
3. Prove end-to-end ingest into Splunk HEC with structured fields.
4. Inform the eventual choice of a production-grade collector.

## Status

| Component | Status |
|---|---|
| Frame Streams unidirectional reader (UNIX socket / TCP) | scaffolded |
| dnstap protobuf decoder | **stubbed** — see `src/dnstap2/decoder.py` |
| Stdout sink | scaffolded |
| JSON-lines file sink | scaffolded |
| Splunk HEC sink | scaffolded |
| CLI | scaffolded |
| Tests | smoke tests only |

The protobuf decoder is intentionally stubbed. Wiring it in requires the canonical `dnstap.proto` from <https://github.com/dnstap/dnstap.pb> and the `protobuf` Python package. See **Adding the real decoder** below.

## Layout

```
DNSTAP2/
├── pyproject.toml
├── README.md
├── .gitignore
├── src/
│   └── dnstap2/
│       ├── __init__.py
│       ├── __main__.py        # `python -m dnstap2`
│       ├── cli.py             # argparse entry point
│       ├── framestream.py     # Frame Streams (fstrm) unidirectional reader
│       ├── decoder.py         # dnstap protobuf decoder (stub + extension point)
│       ├── collector.py       # listens on UNIX / TCP, hands frames to a sink
│       └── sinks/
│           ├── __init__.py
│           ├── base.py
│           ├── stdout.py
│           ├── jsonl.py
│           └── splunk_hec.py
├── tests/
│   ├── __init__.py
│   └── test_framestream.py
└── docs/
    └── design.md
```

## Install

```bash
cd ~/Projects/DNSTAP2
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

## Run

Listen on a UNIX socket (the typical InfoBlox/BIND target):

```bash
dnstap2 --unix /tmp/dnstap.sock --sink stdout
```

Listen on TCP:

```bash
dnstap2 --tcp 0.0.0.0:6000 --sink stdout
```

Forward to a JSON-lines file:

```bash
dnstap2 --unix /tmp/dnstap.sock --sink jsonl --path /var/log/dnstap.jsonl
```

Forward to Splunk HEC:

```bash
export SPLUNK_HEC_TOKEN=...your token...
dnstap2 --unix /tmp/dnstap.sock \
        --sink splunk \
        --splunk-url https://splunk.example.com:8088/services/collector/event \
        --splunk-index dns_dnstap \
        --splunk-sourcetype dnstap:json
```

## Pointing InfoBlox / BIND at it

For a quick BIND lab test, in `named.conf`:

```text
options {
  dnstap { client; resolver; auth; };
  dnstap-output unix "/tmp/dnstap.sock";
};
```

For InfoBlox NIOS — verify the exact configuration surface against your build's documentation during the Phase-1 validation step. Treat the BIND form above as a reference for what the data shape should look like, not as a config to paste into NIOS.

## Adding the real decoder

The `decoder.decode_frame()` function currently returns a minimal placeholder dict (`{"raw_bytes": N, "sha256": ..., "_decoded": false}`). To wire in real dnstap decoding:

1. Get `dnstap.proto` from <https://github.com/dnstap/dnstap.pb>.
2. Compile it:
   ```bash
   pip install protobuf grpcio-tools
   python -m grpc_tools.protoc -Iproto --python_out=src/dnstap2/_pb proto/dnstap.proto
   ```
3. Replace the stub in `decoder.py` with a call to `Dnstap.FromString(payload)` and project the fields you want.

The framing layer (`framestream.py`) and sinks are independent of this and don't need to change.

## Tests

```bash
pytest
```

## Caveats

- This is a lab tool. It does no auth, TLS, or back-pressure beyond what the OS gives you.
- Frame Streams here implements only the **unidirectional content stream** mode, which is what DNS servers send by default. Bidirectional handshakes are not implemented.
- The Splunk HEC sink uses synchronous `urllib`. For real load, swap to an async client and add batching.
- Version claims about InfoBlox NIOS dnstap support belong in the proposal report (`ClaudePreso/report.html`), not here. This repo's job is to be the small thing that proves the bytes flow end to end.

## License

MIT
