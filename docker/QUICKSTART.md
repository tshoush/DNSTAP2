# Docker QUICKSTART — `dnstap2` debug collector

A 5-minute path to a running containerized `dnstap2` debug collector. For the
production (native, no-Docker) pipeline see the repo-root `../QUICKSTART.md`.

> **Scope.** These images package only the Phase-1 `dnstap2` Python *debug
> collector* (`dnstap2 --tcp … --sink …`), not the production Vector /
> DNS-collector data plane. See `../CLAUDE.md`.

## 0. Prerequisites

- Docker Engine or Docker Desktop.
- Build from the **repo root** — the build context needs `src/` and
  `pyproject.toml`. Always pass `-f docker/<file> .`.

```bash
cd /home/tmsho448/DNSTAP2
```

## 1. Pick your image

| Target | Dockerfile | Notes |
|---|---|---|
| macOS / general dev | `docker/Dockerfile.mac` | `python:3.12-slim`, fast build, multi-arch. |
| RHEL 7.9 | `docker/Dockerfile.rhel7.9` | Compiles OpenSSL 1.1.1 + CPython 3.11 from source (multi-minute first build). See `install-redhat.md`. |

## 2. Build

```bash
# macOS / dev
docker build -f docker/Dockerfile.mac -t dnstap2:mac .

# RHEL 7.9
docker build -f docker/Dockerfile.rhel7.9 -t dnstap2:rhel7.9 .
```

## 3. Run (print decoded events to stdout)

```bash
docker run --rm -p 6000:6000 dnstap2:mac --tcp 0.0.0.0:6000 --sink stdout
```

The collector now listens for dnstap Frame Streams on TCP `6000`. Point your
DNS server (or the synthetic generator below) at `host:6000`.

## 4. Smoke-test with synthetic traffic

In a second terminal, drive the listener with the repo's synthetic generator:

```bash
python scripts/dnstap_synth.py --tcp 127.0.0.1:6000
```

You should see decoded events scrolling in the container's stdout.

## 5. Common sinks

**Archive to a JSONL file on the host:**

```bash
mkdir -p out
docker run --rm -p 6000:6000 -v "$PWD/out":/data dnstap2:mac \
    --tcp 0.0.0.0:6000 --sink jsonl --path /data/events.jsonl
```

**Forward to Splunk HEC** (token via env — never baked into the image):

```bash
docker run --rm -p 6000:6000 -e SPLUNK_HEC_TOKEN=... dnstap2:mac \
    --tcp 0.0.0.0:6000 --sink splunk \
    --splunk-url https://splunk.example.com:8088/services/collector/event
```

## 6. Stop

`Ctrl-C` (the container runs in the foreground with `--rm`, so it cleans up).

## Troubleshooting

- **Nothing decoded** — `src/dnstap2/decoder.py` is a deliberate stub; the debug
  collector counts/derives frames, the real protobuf decode happens in Vector
  in production. This is expected (see `../CLAUDE.md`).
- **InfoBlox can't reach the collector on WSL2** — the grid master can't address
  the WSL VM, only the Windows host. Use mirrored networking or `netsh
  portproxy`. See the repo-root `../QUICKSTART.md`.
- **RHEL build fails on `ssl`** — confirm OpenSSL 1.1.1 built before Python; see
  `install-redhat.md`.
