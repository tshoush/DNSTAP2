# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

DNSTAP2 captures DNS query telemetry from **InfoBlox NIOS** via **dnstap** (Frame Streams over TCP) and ships it to **Splunk** (forensics/audit) + **Prometheus** (ops metrics) — **native binaries, no Docker, no JVM**. It exists to replace reactive DNS query logging (which degrades DNS performance and has to be turned off) with always-on, out-of-band telemetry.

Read `ARCHITECTURE.md` for the design and decision rationale; `QUICKSTART.md` for the setup walkthrough.

## Two things that are easy to confuse

**1. The production data plane is Vector, NOT the `dnstap2` Python library.** `src/dnstap2/` is a Phase-1 validation/debug tool only (synthetic injection, frame counting, manual decode). Its `decoder.py` is a deliberate stub — Vector does the real protobuf decoding in production. Do not turn `dnstap2` into the production receiver.

**2. There are two parallel ways to deploy, by design:**

| | Python orchestration | Standalone bash installers |
|---|---|---|
| Entry point | `scripts/setup.sh` → `scripts/*.py` | `scripts/install_*.sh` |
| Driven by | `config.toml` + `.venv` | env-var tunables, no config.toml, no venv |
| Configs | rendered from `templates/*.tmpl` | known-good config baked into the script |
| Use when | full repeatable install from config | one-shot install on a fresh RHEL box |

When changing pipeline behavior (ports, field paths, metric names), the change usually has to land in **both** the template (`templates/vector.toml.tmpl`) and the relevant standalone installer (`scripts/install_dnstap_receiver.sh`) to keep them in sync.

**Two receiver implementations also coexist** — Vector and `dmachard/DNS-collector` — on deliberately distinct ports/users/paths so they can run side-by-side for A/B or instant fallback. Keep them distinct; don't collapse them:

| | Vector (`install_dnstap_receiver.sh`) | DNS-collector (`install_dnscollector_receiver.sh`) |
|---|---|---|
| service / user | `vector` | `dnscollector` |
| dnstap port | `:6000` | `:6001` |
| metrics | `:9598`, `dnstap_*` | `:9599`, `dnscollector_*` |
| archive | `events.jsonl` | `dnscollector-events.jsonl` |

## Commands

```bash
# First-time setup (interactive: detects OS/WSL, prompts for python3.11+, creates .venv,
# pip install -e ".[dev]", records interpreter to .python-path, runs smoke tests)
./scripts/bootstrap.sh
./scripts/bootstrap.sh --recreate      # blow away and rebuild .venv

# One-shot orchestrator — connectivity check → install Vector/Prometheus → render configs
# → InfoBlox dnstap config. Auto-flips to --no-systemd when no systemd is present (e.g. WSL2).
./scripts/setup.sh                      # DRY-RUN for the InfoBlox step
./scripts/setup.sh --apply              # actually PUT the InfoBlox dnstap config
./scripts/setup.sh --skip-install       # render configs only
./scripts/setup.sh --no-systemd         # foreground mode (no systemd units)

# Tests / lint / types (after bootstrap, or: pip install -e ".[dev]")
pytest                                  # full suite
pytest tests/test_framestream.py        # one file
pytest tests/test_platform_info.py -k musl   # one test
ruff check .
mypy src scripts                        # strict mode (see [tool.mypy])

# End-to-end verification
python scripts/test_dnstap_flow.py --config config.toml --seconds 30
curl -s http://localhost:9598/metrics | grep dnstap_
```

The `dnstap2` console script (`dnstap2 --tcp 0.0.0.0:6000 --sink stdout`) is the debug collector — see `src/dnstap2/cli.py` for sinks (`stdout`, `jsonl`, `splunk`).

## Conventions that matter

- **Secrets only via env vars**, never committed: `INFOBLOX_PASSWORD`, `SPLUNK_HEC_TOKEN`. `config.toml` fields for these are left blank and resolved from env in `scripts/lib/config.py:_resolve_secret`. `config.toml` is gitignored; only `config.example.toml` is committed.
- **InfoBlox writes are dry-run by default.** `configure_infoblox_dnstap.py` requires an explicit `--apply`, snapshots current `member:dns` state to `snapshots/member-dns-pre-<ts>.json` first, and rollback is PUTting that snapshot back.
- **WAPI field names are discovered, not hardcoded.** NIOS builds vary, so the script reads the `member:dns` schema (`?_schema=1`) and maps config knobs to real field names via substring heuristics in `FIELD_HINTS`. If a build uses unexpected names, edit `FIELD_HINTS` rather than hardcoding.
- **Python `scripts/*.py` are run from the repo root.** They do `sys.path.insert(0, parents[1])` then `from scripts.lib import ...`, so `scripts/lib/` is an importable package only when CWD is the repo root (which `setup.sh` enforces via `cd "$REPO_ROOT"`).
- Runtime is **stdlib-only** (`tomllib`, `urllib`, `ssl`, `socket`, `string.Template`). Keep it that way — `[project].dependencies` is intentionally empty. No Jinja, no requests/httpx, no protobuf at runtime (the protobuf dep is commented out until the decoder stub is replaced).

## Platform adaptation (the non-obvious part)

`scripts/lib/platform_info.py` detects the host at install time and the installers adapt — you don't branch on platform yourself:

- **glibc < 2.28** (e.g. RHEL 7's 2.17) → `uses_musl_vector` is True → install the `linux-musl` Vector build instead of `linux-gnu`. Prometheus is a static Go binary, so it has no glibc concern.
- **systemd version** gates which unit directives are emitted: `StateDirectory=` and dynamic users need 235+, `AmbientCapabilities=` needs 229+. `systemd_unit()` omits what the host's systemd can't parse (RHEL 7 ships 219).
- These behaviors are regression-tested against hand-built `HostInfo` fixtures in `tests/test_platform_info.py` — no real RHEL 7 / macOS host needed in CI. When adding platform logic, add a fixture there.

**WSL2 networking caveat** (not a code issue): InfoBlox dials *into* the receiver, and from the grid master your WSL VM isn't addressable — only the Windows host is. Fix with mirrored networking (Win11 22H2+) or `netsh portproxy`, and set `receiver.advertised_host` to the Windows host LAN IP. See `QUICKSTART.md`.

## Marriott git

This repo also lives on `git.marriott.com`. Per the workspace `~/CLAUDE.md`, push there with `~/bin/marriott-git-push.sh <repo> <file-or-dir> "<msg>"`; never inline credentials.
