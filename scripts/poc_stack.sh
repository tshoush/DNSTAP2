#!/usr/bin/env bash
# poc_stack.sh — one command to check / start / stop / restart the whole POC
# stack on this box. Wraps the systemd units in the right order so you don't
# have to remember names or dependencies.
#
# Order matters: Loki must be up before DNS-collector (its lokiclient output
# crash-loops if Loki is unreachable). start brings deps up first; stop tears
# down in reverse.
#
# Usage:
#   ./scripts/poc_stack.sh status            # no root needed
#   sudo ./scripts/poc_stack.sh start
#   sudo ./scripts/poc_stack.sh stop
#   sudo ./scripts/poc_stack.sh restart
#
# Units it manages (skips any not installed on this box):
#   loki prometheus alertmanager grafana(-server) vector dnscollector SplunkForwarder
set -uo pipefail

UF_HOME=/opt/splunkforwarder

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

# Resolve grafana's unit name (varies: grafana vs grafana-server).
GRAFANA=""
for u in grafana grafana-server; do unit_exists "$u" && { GRAFANA="$u"; break; }; done

# Start order (deps -> receivers -> forwarder). Stop is the reverse.
ORDER="loki prometheus alertmanager ${GRAFANA} vector dnscollector SplunkForwarder"
# keep only units that actually exist here
MANAGED=""
for u in $ORDER; do [ -n "$u" ] && unit_exists "$u" && MANAGED="$MANAGED $u"; done
MANAGED="${MANAGED# }"
reverse() { local r=""; for x in $1; do r="$x $r"; done; echo "$r"; }

need_root() { [ "$(id -u)" -eq 0 ] || { echo "ERROR: '$1' needs root (use sudo)."; exit 1; }; }

cmd_status() {
  echo "==> Services"
  for u in $MANAGED; do printf '  %-18s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done
  echo
  echo "==> Listening ports (expected: 6000 vector, 6001 dnscollector, 9598/9599 metrics, 9090 prom, 3100 loki, 3000 grafana, 9093 alertmgr)"
  ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -oE ':(6000|6001|9598|9599|9090|3100|3000|9093)$' | sort -u | sed 's/^/  /' || echo "  (none)"
  echo
  echo "==> Receiver metrics"
  printf '  dnscollector queries: '; curl -s -m3 localhost:9599/metrics 2>/dev/null | awk '/^dnscollector_queries_total/{s+=$2} END{print (s>0?s:"0 / unreachable")}'
  printf '  vector queries:       '; curl -s -m3 localhost:9598/metrics 2>/dev/null | awk '/^dnstap_queries_total/{s+=$2} END{print (s>0?s:"0 / unreachable")}'
  echo
  echo "==> Splunk UF link"
  if [ -f "$UF_HOME/var/log/splunk/splunkd.log" ]; then
    grep "Connected to idx" "$UF_HOME/var/log/splunk/splunkd.log" 2>/dev/null | tail -1 | sed 's/^/  /' || echo "  (no 'Connected to idx' yet)"
  else
    echo "  (UF not installed at $UF_HOME)"
  fi
}

cmd_start() {
  need_root start
  for u in $MANAGED; do
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    echo "  starting $u"; systemctl start "$u" || echo "    ! $u failed to start"
    case "$u" in loki) sleep 3;; esac   # let Loki accept connections before dnscollector
  done
  echo; cmd_status
}

cmd_stop() {
  need_root stop
  for u in $(reverse "$MANAGED"); do echo "  stopping $u"; systemctl stop "$u" 2>/dev/null || true; done
  echo "  done."
}

cmd_restart() { need_root restart; cmd_stop; echo; cmd_start; }

case "${1:-status}" in
  status)  cmd_status ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  *) echo "Usage: $0 {status|start|stop|restart}"; exit 1 ;;
esac
