#!/usr/bin/env bash
# DNSTAP2 — one-shot setup orchestrator.
#
# Prerequisites:
#   ./scripts/bootstrap.sh    # creates .venv and records the Python interpreter
#
# Usage:
#   ./scripts/setup.sh                   # full local install + dry-run InfoBlox
#   ./scripts/setup.sh --configure       # prompt for local IPs, Python bin dir, and config
#   ./scripts/setup.sh --configure-only  # prompt and save config, then exit
#   ./scripts/setup.sh --apply           # also apply the InfoBlox dnstap config
#   ./scripts/setup.sh --skip-install    # render configs only
#   ./scripts/setup.sh --no-systemd      # do not write systemd units (auto-on under WSL2 without systemd)
#   ./scripts/setup.sh --insecure        # skip TLS cert verification on downloads (proxy w/o corp CA)
#   ./scripts/setup.sh --non-interactive # never prompt; require existing config/env

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
INSECURE=0
CONFIGURE=0
CONFIGURE_ONLY=0
NON_INTERACTIVE=0
CONFIG_FILE="${DNSTAP2_CONFIG:-config.toml}"
ENV_FILE="${DNSTAP2_ENV_FILE:-.env.dnstap2}"
CONFIG_FILE_FROM_ARG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)         APPLY=1 ;;
    --skip-install)  SKIP_INSTALL=1 ;;
    --no-systemd)    NO_SYSTEMD=1 ;;
    --insecure)      INSECURE=1 ;;
    --configure)     CONFIGURE=1 ;;
    --configure-only) CONFIGURE=1; CONFIGURE_ONLY=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --config)
      shift
      [[ $# -gt 0 ]] || { echo "--config requires a path" >&2; exit 64; }
      CONFIG_FILE="$1"
      CONFIG_FILE_FROM_ARG=1
      ;;
    -h|--help)       sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 64 ;;
  esac
  shift
done

is_interactive() {
  [[ $NON_INTERACTIVE -eq 0 && -t 0 ]]
}

load_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    # shellcheck disable=SC1090
    set -a
    . "$ENV_FILE"
    set +a
    if [[ $CONFIG_FILE_FROM_ARG -eq 0 && -n "${DNSTAP2_CONFIG:-}" ]]; then
      CONFIG_FILE="$DNSTAP2_CONFIG"
    fi
  fi
}

detect_primary_ipv4() {
  local addresses
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global 2>/dev/null \
      | awk '{split($4, a, "/"); if (a[1] !~ /^127\./) {print a[1]; exit}}'
    return
  fi
  addresses="$(hostname -I 2>/dev/null || true)"
  awk '{print $1}' <<<"$addresses"
}

config_get() {
  local key="$1"
  "$PY" - "$CONFIG_FILE" "$key" <<'PY'
from __future__ import annotations

import sys
import tomllib
from pathlib import Path
from typing import Any

config_path = Path(sys.argv[1])
key = sys.argv[2].split(".")

def load(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("rb") as fp:
        return tomllib.load(fp)

def merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(result.get(k), dict):
            result[k] = merge(result[k], v)
        else:
            result[k] = v
    return result

data = merge(load(Path("config.example.toml")), load(config_path))
cur: Any = data
for part in key:
    if not isinstance(cur, dict) or part not in cur:
        print("")
        raise SystemExit(0)
    cur = cur[part]
if isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PY
}

config_attr() {
  local key="$1"
  "$PY" - "$CONFIG_FILE" "$key" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))
from scripts.lib import config as cfgmod  # noqa: E402

cur = cfgmod.load(sys.argv[1])
for part in sys.argv[2].split("."):
    cur = getattr(cur, part)
print(cur)
PY
}

prompt_text() {
  local label="$1"
  local default="$2"
  local outvar="$3"
  local required="${4:-0}"
  local choice value

  if is_interactive; then
    if [[ -n "$default" ]]; then
      printf "  %s [%s]: " "$label" "$default"
    else
      printf "  %s: " "$label"
    fi
    read -r choice
  else
    choice=""
  fi

  value="${choice:-$default}"
  if [[ $required -eq 1 && -z "$value" ]]; then
    echo "  ! $label is required" >&2
    exit 65
  fi
  printf -v "$outvar" '%s' "$value"
}

prompt_secret() {
  local label="$1"
  local outvar="$2"
  local has_existing="${3:-}"
  local choice

  if is_interactive; then
    if [[ -n "$has_existing" ]]; then
      printf "  %s [leave blank to keep existing]: " "$label"
    else
      printf "  %s: " "$label"
    fi
    read -r -s choice
    printf "\n"
  else
    choice=""
  fi

  printf -v "$outvar" '%s' "$choice"
}

prompt_bool() {
  local label="$1"
  local default="$2"
  local outvar="$3"
  local suffix choice value

  if [[ "$default" == "true" ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi

  if is_interactive; then
    printf "  %s [%s]: " "$label" "$suffix"
    read -r choice
  else
    choice=""
  fi

  case "${choice:-$default}" in
    y|Y|yes|YES|true|TRUE|1) value="true" ;;
    n|N|no|NO|false|FALSE|0|"") value="false" ;;
    *) echo "  ! expected yes or no for $label" >&2; exit 65 ;;
  esac
  printf -v "$outvar" '%s' "$value"
}

find_python_in_dir() {
  local bin_dir="$1"
  local candidate ver major minor

  for candidate in \
    "$bin_dir/python3.13" \
    "$bin_dir/python3.12" \
    "$bin_dir/python3.11" \
    "$bin_dir/python3" \
    "$bin_dir/python"; do
    if [[ -x "$candidate" ]]; then
      ver="$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")"
      major="${ver%%.*}"
      minor="${ver##*.}"
      if [[ "$major" -gt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -ge 11 ]]; }; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

run_configuration_wizard() {
  if ! is_interactive; then
    echo "  ! cannot prompt for local configuration without an interactive terminal." >&2
    echo "    Run ./scripts/setup.sh --configure once, or provide --config with a ready file." >&2
    exit 65
  fi

  local auto_ip python_bin_default selected_python
  local ib_host ib_user ib_pass ib_wapi ib_tls ib_timeout
  local recv_listen recv_port recv_adv recv_adv_port
  local vector_metrics vector_jsonl prom_listen prom_interval
  local splunk_enabled splunk_url splunk_token splunk_index
  local python_bin_dir

  echo "==> Local configuration wizard"
  echo "  Press Enter to keep the value shown in brackets."

  auto_ip="$(detect_primary_ipv4)"
  python_bin_default="$(cat .python-bin-dir 2>/dev/null || true)"
  if [[ -z "$python_bin_default" && -f .python-path ]]; then
    python_bin_default="$(dirname "$(cat .python-path)")"
  fi
  if [[ -z "$python_bin_default" ]]; then
    python_bin_default="/usr/local/bin"
  fi

  prompt_text "Python binary directory" "$python_bin_default" python_bin_dir 1
  if [[ ! -d "$python_bin_dir" ]]; then
    echo "  ! Python binary directory does not exist: $python_bin_dir" >&2
    exit 65
  fi
  python_bin_dir="$(cd "$python_bin_dir" && pwd -P)"
  # Persist the directory only once it is known to hold a usable interpreter —
  # a bad value here is fed back to bootstrap.sh on later runs.
  if selected_python="$(find_python_in_dir "$python_bin_dir")"; then
    printf '%s\n' "$python_bin_dir" > .python-bin-dir
    chmod 600 .python-bin-dir
    printf '%s\n' "$selected_python" > .python-path
    chmod 600 .python-path
  else
    echo "  ! no Python 3.11+ executable found in $python_bin_dir — not saving it." >&2
    echo "    Keeping the active venv for this run; rerun bootstrap after installing Python there." >&2
    python_bin_dir=""
  fi

  prompt_text "InfoBlox Grid Master IP/hostname" "$(config_get infoblox.host)" ib_host 1
  prompt_text "InfoBlox WAPI username" "$(config_get infoblox.username)" ib_user 1
  prompt_secret "InfoBlox WAPI password" ib_pass "${INFOBLOX_PASSWORD:-}"
  prompt_text "InfoBlox WAPI version" "$(config_get infoblox.wapi_version)" ib_wapi 1
  prompt_bool "Verify InfoBlox TLS certificate" "$(config_get infoblox.verify_tls)" ib_tls
  prompt_text "InfoBlox WAPI timeout seconds" "$(config_get infoblox.timeout)" ib_timeout 1

  recv_adv="$(config_get receiver.advertised_host)"
  if [[ -z "$recv_adv" || "$recv_adv" == "0.0.0.0" ]]; then
    recv_adv="$auto_ip"
  fi
  prompt_text "Receiver advertised IP reachable from InfoBlox" "$recv_adv" recv_adv 1
  prompt_text "Receiver listen IP" "$(config_get receiver.listen_host)" recv_listen 1
  prompt_text "Receiver dnstap listen port" "$(config_get receiver.listen_port)" recv_port 1
  prompt_text "Receiver advertised port" "$(config_get receiver.advertised_port)" recv_adv_port 1
  prompt_text "Vector metrics listen address" "$(config_get vector.metrics_listen)" vector_metrics 1
  prompt_text "Vector JSONL archive path" "$(config_get vector.jsonl_path)" vector_jsonl 0
  prompt_text "Prometheus listen address" "$(config_get prometheus.listen)" prom_listen 1
  prompt_text "Prometheus scrape interval" "$(config_get prometheus.scrape_interval)" prom_interval 1

  prompt_bool "Enable Splunk HEC forwarding" "$(config_get splunk.enabled)" splunk_enabled
  prompt_text "Splunk HEC URL" "$(config_get splunk.hec_url)" splunk_url 0
  if [[ "$splunk_enabled" == "true" ]]; then
    prompt_secret "Splunk HEC token" splunk_token "${SPLUNK_HEC_TOKEN:-}"
  else
    splunk_token=""
  fi
  prompt_text "Splunk index" "$(config_get splunk.index)" splunk_index 0

  "$PY" scripts/configure_local_settings.py \
    --config "$CONFIG_FILE" \
    --env-file "$ENV_FILE" \
    --env "DNSTAP2_CONFIG=$CONFIG_FILE" \
    --env "DNSTAP2_PYTHON_BIN_DIR=$python_bin_dir" \
    --set "infoblox.host=$ib_host" \
    --set "infoblox.username=$ib_user" \
    --set "infoblox.wapi_version=$ib_wapi" \
    --set "infoblox.verify_tls=$ib_tls" \
    --set "infoblox.timeout=$ib_timeout" \
    --set "receiver.listen_host=$recv_listen" \
    --set "receiver.listen_port=$recv_port" \
    --set "receiver.advertised_host=$recv_adv" \
    --set "receiver.advertised_port=$recv_adv_port" \
    --set "vector.metrics_listen=$vector_metrics" \
    --set "vector.jsonl_path=$vector_jsonl" \
    --set "prometheus.listen=$prom_listen" \
    --set "prometheus.scrape_interval=$prom_interval" \
    --set "splunk.enabled=$splunk_enabled" \
    --set "splunk.hec_url=$splunk_url" \
    --set "splunk.index=$splunk_index" \
    --secret "INFOBLOX_PASSWORD=$ib_pass" \
    --secret "SPLUNK_HEC_TOKEN=$splunk_token"

  load_env_file
}

load_env_file

# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap check
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -d .venv ]] || [[ ! -x .venv/bin/python ]]; then
  echo "  ! .venv missing. Running ./scripts/bootstrap.sh first." >&2
  BOOTSTRAP_ARGS=()
  if [[ -n "${DNSTAP2_PYTHON_BIN_DIR:-}" ]]; then
    BOOTSTRAP_ARGS+=(--python-bin-dir "$DNSTAP2_PYTHON_BIN_DIR")
  fi
  # ${arr[@]+...} guard: plain "${arr[@]}" on an empty array is an unbound-variable
  # error under set -u on bash <= 4.3 (RHEL 7 ships 4.2, macOS ships 3.2).
  bash "$SCRIPT_DIR/bootstrap.sh" ${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"}
fi
PY=".venv/bin/python"

# ─────────────────────────────────────────────────────────────────────────────
# TLS trust — point Python at the system CA bundle so HTTPS downloads
# (Vector/Prometheus from GitHub) can verify certs.
#
# A self-compiled / pyenv Python often has an OpenSSL default cert path that
# doesn't exist on the host, which surfaces as:
#   urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] ... unable to get local
#   issuer certificate
# On RHEL the corporate (Marriott) root CA is already in the system trust
# store, so simply exporting SSL_CERT_FILE/SSL_CERT_DIR fixes verification
# without disabling it. We only set this if the user hasn't already.
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${SSL_CERT_FILE:-}" ]]; then
  for _ca in \
    /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/ssl/certs/ca-bundle.crt \
    /etc/ssl/cert.pem ; do
    if [[ -r "$_ca" ]]; then
      export SSL_CERT_FILE="$_ca"
      [[ -d /etc/ssl/certs ]]    && export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"
      [[ -d /etc/pki/tls/certs ]] && export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/pki/tls/certs}"
      echo "  TLS  : using system CA bundle $SSL_CERT_FILE for HTTPS downloads"
      break
    fi
  done
  if [[ -z "${SSL_CERT_FILE:-}" ]]; then
    echo "  ! TLS: no system CA bundle found. If a download fails with"
    echo "        CERTIFICATE_VERIFY_FAILED, export SSL_CERT_FILE=/path/to/ca-bundle.crt"
    echo "        and re-run, or pre-stage the tarball into ./vendor/ (see QUICKSTART)."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# TLS reachability probe — if HTTPS to the download host still can't verify
# (e.g. a TLS-intercepting proxy whose corporate root CA is not installed),
# fall back to unverified downloads automatically. This only affects the
# Vector/Prometheus tarball fetch; the SHA256 of the tarball is still checked.
# Force it with --insecure or DNSTAP_INSECURE_DOWNLOADS=1.
# ─────────────────────────────────────────────────────────────────────────────
if [[ $INSECURE -eq 1 ]]; then
  export DNSTAP_INSECURE_DOWNLOADS=1
fi
if [[ "${DNSTAP_INSECURE_DOWNLOADS:-}" != "1" ]] && [[ $SKIP_INSTALL -eq 0 ]]; then
  if ! $PY - <<'PYEOF' 2>/dev/null
import urllib.request
urllib.request.urlopen("https://github.com", timeout=15).read(1)
PYEOF
  then
    echo "  ! TLS: HTTPS verification to github.com failed even with the system CA bundle."
    echo "        Falling back to UNVERIFIED downloads (no corporate root CA available)."
    echo "        The downloaded tarball is still integrity-checked via its SHA256."
    export DNSTAP_INSECURE_DOWNLOADS=1
  fi
fi
if [[ "${DNSTAP_INSECURE_DOWNLOADS:-}" == "1" ]]; then
  echo "  TLS  : insecure download mode ON (certificate verification disabled)"
fi

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
echo "  config    : $CONFIG_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Config sanity
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" || $CONFIGURE -eq 1 ]]; then
  run_configuration_wizard
fi
chmod 600 "$CONFIG_FILE" 2>/dev/null || true

# Exit 0: password available. Exit 1: config loads but no password.
# Exit 2: config failed to load (real error already printed to stderr).
PASSWORD_RC=0
"$PY" - "$CONFIG_FILE" <<'PY' || PASSWORD_RC=$?
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))
from scripts.lib import config as cfgmod  # noqa: E402

try:
    cfg = cfgmod.load(sys.argv[1])
except Exception as exc:
    print(f"  ! failed to load {sys.argv[1]}: {exc}", file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(0 if cfg.infoblox.password else 1)
PY

if [[ $PASSWORD_RC -eq 2 ]]; then
  echo "  ! $CONFIG_FILE is invalid — fix it (or rerun ./scripts/setup.sh --configure-only)." >&2
  exit 65
fi

if [[ $CONFIGURE_ONLY -eq 1 ]]; then
  echo "==> configuration saved"
  echo "  config : $CONFIG_FILE"
  echo "  env    : $ENV_FILE"
  if [[ $PASSWORD_RC -ne 0 ]]; then
    echo "  note   : no InfoBlox password stored yet — rerun --configure-only and enter it,"
    echo "           or export INFOBLOX_PASSWORD before the full setup run."
  fi
  exit 0
fi

if [[ $PASSWORD_RC -ne 0 ]]; then
  echo "  ! Neither INFOBLOX_PASSWORD env var nor [infoblox].password in $CONFIG_FILE is set." >&2
  echo "    Run ./scripts/setup.sh --configure and enter the password, or export INFOBLOX_PASSWORD." >&2
  exit 66
fi

SYSTEMD_FLAG=""
if [[ $NO_SYSTEMD -eq 1 ]]; then
  SYSTEMD_FLAG="--no-systemd"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — connectivity check
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [1/6] check_infoblox.py"
"$PY" scripts/check_infoblox.py --config "$CONFIG_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — install Vector
# ─────────────────────────────────────────────────────────────────────────────
if [[ $SKIP_INSTALL -eq 0 ]]; then
  echo "==> [2/6] install_vector.py"
  "$PY" scripts/install_vector.py --config "$CONFIG_FILE" $SYSTEMD_FLAG
else
  echo "==> [2/6] install_vector.py SKIPPED (--skip-install)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — install Prometheus
# ─────────────────────────────────────────────────────────────────────────────
if [[ $SKIP_INSTALL -eq 0 ]]; then
  echo "==> [3/6] install_prometheus.py"
  "$PY" scripts/install_prometheus.py --config "$CONFIG_FILE" $SYSTEMD_FLAG
else
  echo "==> [3/6] install_prometheus.py SKIPPED (--skip-install)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — render configs
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [4/6] render Vector and Prometheus configs"
VECTOR_CFG="$(config_attr vector.config_path)"
PROM_CFG="$(config_attr prometheus.config_path)"

# Try to write directly; fall back to sudo if the destination is /etc/-owned.
if ! "$PY" scripts/render_vector_config.py --config "$CONFIG_FILE" --output "$VECTOR_CFG" 2>/dev/null; then
  echo "  needs elevated rights to write $VECTOR_CFG — using sudo"
  "$PY" scripts/render_vector_config.py --config "$CONFIG_FILE" | sudo tee "$VECTOR_CFG" > /dev/null
fi
if ! "$PY" scripts/render_prometheus_config.py --config "$CONFIG_FILE" --output "$PROM_CFG" 2>/dev/null; then
  echo "  needs elevated rights to write $PROM_CFG — using sudo"
  "$PY" scripts/render_prometheus_config.py --config "$CONFIG_FILE" --existing "$PROM_CFG" | sudo tee "$PROM_CFG" > /dev/null
fi
echo "  wrote $VECTOR_CFG"
echo "  wrote $PROM_CFG"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — configure InfoBlox (dry-run by default)
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [5/6] configure_infoblox_dnstap.py"
if [[ $APPLY -eq 1 ]]; then
  "$PY" scripts/configure_infoblox_dnstap.py --config "$CONFIG_FILE" --apply
else
  echo "  (dry-run; re-run setup.sh with --apply to actually push the change)"
  "$PY" scripts/configure_infoblox_dnstap.py --config "$CONFIG_FILE"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6 — service start hints
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [6/6] next steps"
VECTOR_BIN="$(config_attr vector.install_prefix)/bin/vector"
PROM_BIN="$(config_attr prometheus.install_prefix)/bin/prometheus"
PROM_DATA="$(config_attr prometheus.data_dir)"
PROM_LISTEN="$(config_attr prometheus.listen)"
METRICS="$(config_attr vector.metrics_listen)"

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
echo "Verify end-to-end:  $PY scripts/test_dnstap_flow.py --config $CONFIG_FILE"
echo "Prometheus:         http://$PROM_LISTEN"
echo "Vector metrics:     http://$METRICS/metrics"
