#!/usr/bin/env bash
# run_demo.sh — start/stop synthetic dnstap traffic for a live demo.
#
# Wraps scripts/dnstap_synth.py so a presentation is one command. Runs the
# generator DETACHED (survives SSH disconnect) in its own process group, so a
# single --stop cleanly kills it. No sudo, no venv — dnstap_synth is stdlib-only.
#
# Usage:
#   ./scripts/run_demo.sh                 # start: continuous traffic until --stop
#   ./scripts/run_demo.sh --minutes 120   # start: auto-stop after 2 hours
#   ./scripts/run_demo.sh --rate 60       # busier dashboards (default 40/s)
#   ./scripts/run_demo.sh --status        # is it running? show live counters
#   ./scripts/run_demo.sh --stop          # stop it
#
# Options (start mode):
#   --rate N             query/response pairs per second   (default 40)
#   --recursion-ratio R  fraction recursive (cache miss)   (default 0.6)
#   --target host:port   dnstap receiver                   (default 127.0.0.1:6001)
#   --minutes M          auto-stop after M minutes         (default 0 = run forever)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNTH="$SCRIPT_DIR/dnstap_synth.py"
PIDFILE="/tmp/dnstap_demo.pid"
LOG="/tmp/dnstap_demo.log"
METRICS_URL="http://127.0.0.1:9599/metrics"

RATE=40
RATIO=0.6
TARGET="127.0.0.1:6001"
MINUTES=0
ACTION="start"

while [ $# -gt 0 ]; do
  case "$1" in
    --stop)            ACTION="stop" ;;
    --status)          ACTION="status" ;;
    --rate)            RATE="$2"; shift ;;
    --recursion-ratio) RATIO="$2"; shift ;;
    --target)          TARGET="$2"; shift ;;
    --minutes)         MINUTES="$2"; shift ;;
    -h|--help)         sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
  shift
done

PY="$(command -v python3 || command -v python || true)"

is_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

show_counters() {
  echo "  live dnscollector counters (should climb while running):"
  curl -s "$METRICS_URL" 2>/dev/null | grep '^dnscollector_' | grep -v build_info \
    | sed 's/^/    /' || echo "    (metrics endpoint :9599 not reachable)"
}

case "$ACTION" in
  stop)
    if is_running; then
      pid="$(cat "$PIDFILE")"
      # negative PID = kill the whole process group (the loop + its python child)
      kill -TERM "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "-${pid}" 2>/dev/null || true
      echo "==> demo traffic stopped (was PID $pid)"
    else
      echo "==> nothing running (no live PID in $PIDFILE)"
      # belt-and-suspenders: clean up any stray generator
      pkill -f "$SYNTH" 2>/dev/null && echo "    killed a stray dnstap_synth.py" || true
    fi
    rm -f "$PIDFILE"
    ;;

  status)
    if is_running; then
      echo "==> RUNNING (PID $(cat "$PIDFILE")) — log: $LOG"
      tail -n 3 "$LOG" 2>/dev/null | sed 's/^/    /' || true
    else
      echo "==> NOT running"
    fi
    show_counters
    ;;

  start)
    [ -n "$PY" ] || { echo "ERROR: no python3 found on PATH." >&2; exit 1; }
    [ -f "$SYNTH" ] || { echo "ERROR: $SYNTH not found." >&2; exit 1; }
    if is_running; then
      echo "==> already running (PID $(cat "$PIDFILE")). Stop it first: $0 --stop" >&2
      exit 1
    fi

    if [ "$MINUTES" -gt 0 ] 2>/dev/null && [ "$MINUTES" != 0 ]; then
      DUR=$(( MINUTES * 60 ))
      # Deadline-bounded RESILIENT loop: re-launch short batches until DUR seconds
      # of wall-clock elapse (bash $SECONDS). If the collector restarts and the
      # generator dies with a broken pipe, the next batch reconnects — the demo
      # survives instead of ending. Stops itself at the deadline.
      CMD="end=$DUR; while [ \$SECONDS -lt \$end ]; do \"$PY\" \"$SYNTH\" --rate $RATE --duration 300 --recursion-ratio $RATIO --target $TARGET || true; sleep 1; done"
      WHAT="for ${MINUTES} min then auto-stop (auto-recovers if the collector restarts)"
    else
      # continuous: restart a fresh 10-min batch forever until the group is killed
      CMD="while true; do \"$PY\" \"$SYNTH\" --rate $RATE --duration 600 --recursion-ratio $RATIO --target $TARGET || true; sleep 1; done"
      WHAT="continuously until --stop (auto-recovers if the collector restarts)"
    fi

    # setsid → new session/process group so --stop can kill the whole tree
    setsid bash -c "$CMD" >"$LOG" 2>&1 </dev/null &
    echo $! > "$PIDFILE"
    sleep 1

    cat <<EOF
==> demo traffic STARTED (PID $(cat "$PIDFILE")) — $WHAT
    rate=${RATE}/s  recursion=${RATIO}  target=${TARGET}
    log: $LOG

Verify (curl-only, no browser needed):
  curl -s $METRICS_URL | grep '^dnscollector_' | grep -v build_info
  tail -f /var/log/dnscollector/dnscollector-events.jsonl
  $0 --status

Stop:
  $0 --stop

Grafana (when reachable):  http://172.25.15.234:3000   (admin/admin)
EOF
    ;;
esac
