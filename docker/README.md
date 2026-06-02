# docker/ — containerized `dnstap2` debug collector

> **Scope note.** The DNSTAP2 production data plane is **native binaries, no
> Docker** (see `../CLAUDE.md`). These images package **only** the Phase-1
> `dnstap2` Python *debug collector* — the `dnstap2 --tcp … --sink …` console
> script used for synthetic injection, frame counting, and manual decode. They
> are a developer/testing convenience, **not** the Vector / DNS-collector
> production receiver. Don't promote them into the production pipeline.

## Images

| File | Base | When to use |
|---|---|---|
| `Dockerfile.mac` | `python:3.12-slim` | Local dev on macOS (Docker Desktop, Apple Silicon or Intel). Lightweight, multi-arch. |
| `Dockerfile.rhel7.9` | `registry.access.redhat.com/ubi7/ubi:7.9` | Reproduce the RHEL 7.9 target (glibc 2.17). Builds OpenSSL 1.1.1 + Python 3.11 from source because the base ships neither. |

Both build from the **repo root** (the build context needs `src/` and
`pyproject.toml`), so pass `-f docker/<file>` and `.` as the context.

## Build & run

```bash
# from the repo root
cd /home/tmsho448/DNSTAP2

# macOS dev image
docker build -f docker/Dockerfile.mac -t dnstap2:mac .
docker run --rm -p 6000:6000 dnstap2:mac --tcp 0.0.0.0:6000 --sink stdout

# RHEL 7.9 image (first build is slow — it compiles OpenSSL + CPython)
docker build -f docker/Dockerfile.rhel7.9 -t dnstap2:rhel7.9 .
docker run --rm -p 6000:6000 dnstap2:rhel7.9 --tcp 0.0.0.0:6000 --sink stdout
```

### Archive decoded events to the host (JSONL sink)

```bash
mkdir -p out
docker run --rm -p 6000:6000 -v "$PWD/out":/data dnstap2:mac \
    --tcp 0.0.0.0:6000 --sink jsonl --path /data/events.jsonl
```

### Forward to Splunk HEC (token via env, never baked into the image)

```bash
docker run --rm -p 6000:6000 -e SPLUNK_HEC_TOKEN=... dnstap2:mac \
    --tcp 0.0.0.0:6000 --sink splunk \
    --splunk-url https://splunk.example.com:8088/services/collector/event
```

## Notes

- The container runs as the unprivileged user `dnstap` (uid 10001) and only
  binds the high port `6000`, so no extra capabilities are needed.
- `Dockerfile.rhel7.9` compiles **OpenSSL 1.1.1** and **CPython 3.11** from
  source. RHEL 7.9 ships OpenSSL 1.0.2k and Python 3.6, but `dnstap2` needs
  Python ≥ 3.11 and CPython 3.10+ needs OpenSSL ≥ 1.1.1 — the same glibc-2.17
  reality handled by `../scripts/lib/platform_info.py`. Expect a multi-minute
  first build.
- Override the OpenSSL/Python versions via build args:
  `--build-arg PYTHON_VERSION=3.11.10 --build-arg OPENSSL_VERSION=1.1.1w`.
