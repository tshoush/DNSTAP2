#!/usr/bin/env bash
# install_stack.sh — one-shot installer for the DNSTAP2 observability stack that
# sits BEHIND the DNS-collector receiver (install_dnscollector_receiver.sh).
#
# Runs the standalone bash installers in dependency order:
#     1. Loki         (:3100)  log store — DNS-collector pushes events here
#     2. Prometheus   (:9090)  scrapes dnscollector_* metrics on :9599
#     3. Grafana      (:3000)  dashboards; auto-provisions Prometheus + Loki
#     4. Alertmanager (:9093)  alert routing (appends rules to Prometheus)
#
# Then restarts dnscollector — if it was crash-looping because its lokiclient
# output could not reach Loki, Loki now being up on :3100 fixes that — and prints
# a health summary for the whole stack.
#
# This is the DNS-collector counterpart to setup.sh (which drives the Vector
# path). It does NOT touch Vector, config.toml, or the .venv.
#
# Usage:
#   sudo ./scripts/install_stack.sh                 # loki + prometheus + grafana + alertmanager
#   sudo ./scripts/install_stack.sh --skip-alertmanager
#   sudo ./scripts/install_stack.sh --skip-collector-restart
#
# Env passthrough (see each install_*.sh for the full list):
#   LOKI_VERSION PROM_VERSION GRAFANA_VERSION AM_VERSION
#   DNSCOLLECTOR_TARGET (default localhost:9599)
#   DNSTAP_INSECURE_DOWNLOADS=1  # skip TLS verify if behind a proxy w/o corp CA
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo ./scripts/install_stack.sh)."; exit 1; }

WITH_ALERTMANAGER=1
RESTART_COLLECTOR=1
for arg in "$@"; do
  case "$arg" in
    --skip-alertmanager)        WITH_ALERTMANAGER=0 ;;
    --skip-collector-restart)   RESTART_COLLECTOR=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

# Run an installer with a banner; on failure say which step died (set -e aborts).
run_step() {
  local label="$1"; shift
  echo
  echo "═════════════════════════════════════════════════════════════════════"
  echo "  $label"
  echo "═════════════════════════════════════════════════════════════════════"
  bash "$SCRIPT_DIR/$1"
}

trap 'echo; echo "!! install_stack.sh aborted — see the failing step above." >&2' ERR

run_step "[1/4] Loki — log store (:3100)"           install_loki.sh
run_step "[2/4] Prometheus — metrics (:9090, scrapes :9599)" install_prometheus.sh
run_step "[3/4] Grafana — dashboards (:3000)"        install_grafana.sh
if [ "$WITH_ALERTMANAGER" -eq 1 ]; then
  run_step "[4/4] Alertmanager — alerts (:9093)"     install_alertmanager.sh
else
  echo; echo "  [4/4] Alertmanager SKIPPED (--skip-alertmanager)"
fi

trap - ERR

# ─────────────────────────────────────────────────────────────────────────────
# Restart the DNS-collector receiver now that Loki exists, then summarize health.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$RESTART_COLLECTOR" -eq 1 ] && systemctl list-unit-files | grep -q '^dnscollector\.service'; then
  echo
  echo "==> Restarting dnscollector (Loki is up now — clears lokiclient failures)"
  systemctl restart dnscollector || true
  sleep 5
fi

# Probe an HTTP endpoint; print OK/<code>/down.
probe() {
  local name="$1" url="$2"
  local code
  code=$(curl -s -m3 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
  printf "  %-14s %-34s -> %s\n" "$name" "$url" "${code:-down}"
}

echo
echo "═════════════════════════════════════════════════════════════════════"
echo "  Stack health"
echo "═════════════════════════════════════════════════════════════════════"
for svc in dnscollector loki prometheus grafana-server alertmanager; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
    printf "  %-16s : %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
  fi
done
echo
probe "dnscollector" "http://127.0.0.1:9599/metrics"
probe "loki"         "http://127.0.0.1:3100/ready"
probe "prometheus"   "http://127.0.0.1:9090/-/ready"
probe "grafana"      "http://127.0.0.1:3000/api/health"
if [ "$WITH_ALERTMANAGER" -eq 1 ]; then
  probe "alertmanager" "http://127.0.0.1:9093/-/ready"
fi

cat <<EOF

Done. Open the UIs (replace 172.25.15.234 with this host if different):
  Grafana     http://172.25.15.234:3000   (default login admin / admin)
  Prometheus  http://172.25.15.234:9090
  Loki        http://172.25.15.234:3100   (API only; view logs via Grafana)

If dnscollector still shows 'activating' / metrics 'down' above, grab the error:
  journalctl -u dnscollector --no-pager -n 60
EOF
