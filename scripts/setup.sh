#!/usr/bin/env bash
# DNSTAP2 — one-shot setup orchestrator.
#
# Prerequisites:
#   ./scripts/bootstrap.sh    # creates .venv and records the Python interpreter
#
# Usage:
#   ./scripts/setup.sh                   # full local install + dry-run InfoBlox
#   ./scripts/setup.sh --apply           # also apply the InfoBlox dnstap config
#   ./scripts/setup.sh --skip-install    # render configs only
#   ./scripts/setup.sh --no-systemd      # do not write systemd units (auto-on under WSL2 without systemd)

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APPLY=0
SKIP_INSTALL=0
NO_SYSTEMD=0

for arg in "$@"; do
  case "$arg" in
    --apply)         APPLY=1 ;;
    --skip-install)  SKIP_INSTALL=1 ;;
    --no-systemd)    NO_SYSTEMD=1 ;;
    -h|--help)       sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap check
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -d .venv ]] || [[ ! -x .venv/bin/python ]]; then
  echo "  ! .venv missing. Running ./scripts/bootstrap.sh first." >&2
  bash "$SCRIPT_DIR/bootstrap.sh"
fi
PY=".venv/bin/python"

# ─────────────────────────────────────────────────────────────────────────────
# Auto-detect WSL/no-systemd → flip --no-systemd unless user already passed it
# ─────────────────────────────────────────────────────────────────────────────
if [[ $NO_SYSTEMD -eq 0 ]]; then
  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    echo "  systemd not detected on this host — switching to foreground mode (--no-systemd)."
    NO_SYSTEMD=1
  fi
fi

echo "==> DNSTAP2 setup"
echo "  repo root : $REPO_ROOT"
echo "  python    : $($PY --version 2>&1) ($(cat .python-path 2>/dev/null || echo 'venv'))"
echo "  systemd   : $([[ $NO_SYSTEMD -eq 0 ]] && echo yes || echo no)"

# ─────────────────────────────────────────────────────────────────────────────
# Config sanity
# ─────────────────────────────────────────────────────────────────────────────
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

SYSTEMD_FLAG=""
if [[ $NO_SYSTEMD -eq 1 ]]; then
  SYSTEMD_FLAG="--no-systemd"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — connectivity check
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [1/6] check_infoblox.py"
$PY scripts/check_infoblox.py --config config.toml

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — install Vector
# ─────────────────────────────────────────────────────────────────────────────
if [[ $SKIP_INSTALL -eq 0 ]]; then
  echo "==> [2/6] install_vector.py"
  $PY scripts/install_vector.py --config config.toml $SYSTEMD_FLAG
else
  echo "==> [2/6] install_vector.py SKIPPED (--skip-install)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — install Prometheus
# ─────────────────────────────────────────────────────────────────────────────
if [[ $SKIP_INSTALL -eq 0 ]]; then
  echo "==> [3/6] install_prometheus.py"
  $PY scripts/install_prometheus.py --config config.toml $SYSTEMD_FLAG
else
  echo "==> [3/6] install_prometheus.py SKIPPED (--skip-install)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — render configs
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [4/6] render Vector and Prometheus configs"
VECTOR_CFG="$($PY -c "from scripts.lib import config; print(config.load('config.toml').vector.config_path)")"
PROM_CFG="$($PY -c "from scripts.lib import config; print(config.load('config.toml').prometheus.config_path)")"

# Try to write directly; fall back to sudo if the destination is /etc/-owned.
if ! $PY scripts/render_vector_config.py --config config.toml --output "$VECTOR_CFG" 2>/dev/null; then
  echo "  needs elevated rights to write $VECTOR_CFG — using sudo"
  $PY scripts/render_vector_config.py --config config.toml | sudo tee "$VECTOR_CFG" > /dev/null
fi
if ! $PY scripts/render_prometheus_config.py --config config.toml --output "$PROM_CFG" 2>/dev/null; then
  echo "  needs elevated rights to write $PROM_CFG — using sudo"
  $PY scripts/render_prometheus_config.py --config config.toml | sudo tee "$PROM_CFG" > /dev/null
fi
echo "  wrote $VECTOR_CFG"
echo "  wrote $PROM_CFG"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — configure InfoBlox (dry-run by default)
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [5/6] configure_infoblox_dnstap.py"
if [[ $APPLY -eq 1 ]]; then
  $PY scripts/configure_infoblox_dnstap.py --config config.toml --apply
else
  echo "  (dry-run; re-run setup.sh with --apply to actually push the change)"
  $PY scripts/configure_infoblox_dnstap.py --config config.toml
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6 — service start hints
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [6/6] next steps"
VECTOR_BIN="$($PY -c "from scripts.lib import config; print(config.load('config.toml').vector.install_prefix)")/bin/vector"
PROM_BIN="$($PY -c "from scripts.lib import config; print(config.load('config.toml').prometheus.install_prefix)")/bin/prometheus"
PROM_DATA="$($PY -c "from scripts.lib import config; print(config.load('config.toml').prometheus.data_dir)")"
PROM_LISTEN="$($PY -c "from scripts.lib import config; print(config.load('config.toml').prometheus.listen)")"
METRICS="$($PY -c "from scripts.lib import config; print(config.load('config.toml').vector.metrics_listen)")"

if [[ $NO_SYSTEMD -eq 1 ]]; then
  cat <<EOF
  Foreground mode — run these in separate terminals (or under tmux/screen):

    sudo $VECTOR_BIN --config $VECTOR_CFG
    sudo $PROM_BIN --config.file=$PROM_CFG \\
        --storage.tsdb.path=$PROM_DATA \\
        --web.listen-address=$PROM_LISTEN
EOF
else
  cat <<EOF
  Systemd mode:
    sudo systemctl daemon-reload
    sudo systemctl enable --now vector
    sudo systemctl enable --now prometheus
EOF
fi
echo
echo "Verify end-to-end:  $PY scripts/test_dnstap_flow.py --config config.toml"
echo "Prometheus:         http://$PROM_LISTEN"
echo "Vector metrics:     http://$METRICS/metrics"
