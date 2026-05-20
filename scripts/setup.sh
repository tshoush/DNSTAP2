#!/usr/bin/env bash
# DNSTAP2 — one-shot setup orchestrator.
#
# Runs the Python scripts in the right order. Refuses to do anything
# destructive without an explicit --apply flag for the InfoBlox change.
#
# Usage:
#   ./scripts/setup.sh                   # full local install + dry-run InfoBlox
#   ./scripts/setup.sh --apply           # also apply the InfoBlox dnstap config
#   ./scripts/setup.sh --skip-install    # render configs only
#   ./scripts/setup.sh --no-systemd      # do not write systemd units

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Paths and defaults
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APPLY=0
SKIP_INSTALL=0
NO_SYSTEMD=0
PY="${PYTHON:-python3}"

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    --no-systemd) NO_SYSTEMD=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 64
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Sanity checks
# ─────────────────────────────────────────────────────────────────────────────
echo "==> DNSTAP2 setup"
echo "  repo root : $REPO_ROOT"
echo "  python    : $($PY --version 2>&1)"

if [[ ! -f "config.toml" ]]; then
  echo "  ! config.toml not found. Copying from config.example.toml ..." >&2
  cp config.example.toml config.toml
  echo "    edit config.toml, then re-run." >&2
  exit 65
fi

if [[ -z "${INFOBLOX_PASSWORD:-}" ]]; then
  if ! grep -E '^\s*password\s*=\s*"[^"]+"' config.toml > /dev/null; then
    echo "  ! Neither INFOBLOX_PASSWORD env var nor [infoblox].password in config.toml is set." >&2
    echo "    export INFOBLOX_PASSWORD=... and re-run." >&2
    exit 66
  fi
fi

# Make sure we have a venv with the package installed for the dnstap2 imports.
if [[ ! -d ".venv" ]]; then
  echo "==> creating .venv"
  "$PY" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -e ".[dev]"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — connectivity check
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [1/6] check_infoblox.py"
python scripts/check_infoblox.py --config config.toml

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — install Vector
# ─────────────────────────────────────────────────────────────────────────────
SYSTEMD_FLAG=""
if [[ "$NO_SYSTEMD" -eq 1 ]]; then
  SYSTEMD_FLAG="--no-systemd"
fi

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  echo "==> [2/6] install_vector.py"
  python scripts/install_vector.py --config config.toml $SYSTEMD_FLAG
else
  echo "==> [2/6] install_vector.py SKIPPED (--skip-install)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — install Prometheus
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  echo "==> [3/6] install_prometheus.py"
  python scripts/install_prometheus.py --config config.toml $SYSTEMD_FLAG
else
  echo "==> [3/6] install_prometheus.py SKIPPED (--skip-install)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — render configs
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [4/6] render Vector and Prometheus configs"
VECTOR_CFG="$(python -c "from scripts.lib import config; print(config.load('config.toml').vector.config_path)")"
PROM_CFG="$(python -c "from scripts.lib import config; print(config.load('config.toml').prometheus.config_path)")"

# These writes go to /etc by default — may need sudo. Try without first.
if ! python scripts/render_vector_config.py --config config.toml --output "$VECTOR_CFG" 2>/dev/null; then
  echo "  needs elevated rights to write $VECTOR_CFG — using sudo"
  python scripts/render_vector_config.py --config config.toml | sudo tee "$VECTOR_CFG" > /dev/null
fi
if ! python scripts/render_prometheus_config.py --config config.toml --output "$PROM_CFG" 2>/dev/null; then
  echo "  needs elevated rights to write $PROM_CFG — using sudo"
  python scripts/render_prometheus_config.py --config config.toml | sudo tee "$PROM_CFG" > /dev/null
fi
echo "  wrote $VECTOR_CFG"
echo "  wrote $PROM_CFG"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — configure InfoBlox (dry-run by default)
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [5/6] configure_infoblox_dnstap.py"
if [[ "$APPLY" -eq 1 ]]; then
  python scripts/configure_infoblox_dnstap.py --config config.toml --apply
else
  echo "  (dry-run; re-run setup.sh with --apply to actually push the change)"
  python scripts/configure_infoblox_dnstap.py --config config.toml
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6 — service start hints
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [6/6] next steps"
if [[ "$NO_SYSTEMD" -eq 1 ]] || ! command -v systemctl >/dev/null 2>&1; then
  echo "  Foreground mode — run these in separate terminals:"
  echo "    sudo $(python -c "from scripts.lib import config; print(config.load('config.toml').vector.install_prefix)")/bin/vector --config $VECTOR_CFG"
  echo "    sudo $(python -c "from scripts.lib import config; print(config.load('config.toml').prometheus.install_prefix)")/bin/prometheus --config.file $PROM_CFG --storage.tsdb.path $(python -c "from scripts.lib import config; print(config.load('config.toml').prometheus.data_dir)") --web.listen-address $(python -c "from scripts.lib import config; print(config.load('config.toml').prometheus.listen)")"
else
  echo "  Systemd mode:"
  echo "    sudo systemctl daemon-reload"
  echo "    sudo systemctl enable --now vector"
  echo "    sudo systemctl enable --now prometheus"
fi
echo
echo "Verify end-to-end:  python scripts/test_dnstap_flow.py --config config.toml"
echo "Prometheus:         http://$(python -c "from scripts.lib import config; print(config.load('config.toml').prometheus.listen)")"
echo "Vector metrics:     http://$(python -c "from scripts.lib import config; print(config.load('config.toml').vector.metrics_listen)")/metrics"
