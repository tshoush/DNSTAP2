#!/usr/bin/env bash
# install_prometheus.sh — install Prometheus (standalone, systemd) on RHEL/CentOS
# 7+ or Debian/Ubuntu (incl. systemd-enabled WSL2). Scrapes the Vector dnstap exporter (:9598) and
# the optional DNS-collector exporter (:9599). Static Go binary — works on glibc
# 2.17 (RHEL 7) and modern Ubuntu alike.
#
# This is the bash counterpart to install_prometheus.py (which is config.toml /
# venv driven). Use this one for the standalone .sh installer set alongside
# install_{loki,alertmanager,grafana}.sh — no Python or config.toml required.
# install_alertmanager.sh later appends rule_files + alerting to the config it
# writes here and reloads Prometheus, so keep the base config rule-free.
#
# Env knobs:
#   PROM_VERSION              (default 2.53.3 — LTS line)
#   PORT                      Prometheus listen port      (default 9090)
#   SCRAPE_INTERVAL           (default 15s)
#   VECTOR_TARGET             Vector metrics       (default localhost:9598)
#   DNSCOLLECTOR_TARGET       DNS-collector metrics (default localhost:9599)
#
# Usage: sudo ./install_prometheus.sh
set -euo pipefail

PROM_VERSION="${PROM_VERSION:-2.53.3}"
PORT="${PORT:-9090}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15s}"
VECTOR_TARGET="${VECTOR_TARGET:-localhost:9598}"
DNSCOLLECTOR_TARGET="${DNSCOLLECTOR_TARGET:-localhost:9599}"
BIN=/usr/local/bin/prometheus
PROMTOOL=/usr/local/bin/promtool
DATA=/var/lib/prometheus
CONF=/etc/prometheus/prometheus.yml
RULES_DIR=/etc/prometheus/rules

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)."; exit 1; }
case "$(uname -m)" in x86_64) A=amd64;; aarch64) A=arm64;; *) echo "unsupported arch"; exit 1;; esac

echo "==> Installing Prometheus ${PROM_VERSION} (${A})"
if [ -x "$BIN" ] && [ -x "$PROMTOOL" ] \
  && "$BIN" --version 2>/dev/null | grep -Fq "$PROM_VERSION" \
  && "$PROMTOOL" --version 2>/dev/null | grep -Fq "$PROM_VERSION"; then
  echo "    already installed, skipping download"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  TARBALL="prometheus-${PROM_VERSION}.linux-${A}"
  URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${TARBALL}.tar.gz"
  echo "    downloading $URL"
  curl -fSL --retry 3 -o "$TMP/prom.tgz" "$URL"
  tar -xzf "$TMP/prom.tgz" -C "$TMP"
  install -m 0755 "$TMP/${TARBALL}/prometheus" "$BIN"
  install -m 0755 "$TMP/${TARBALL}/promtool" "$PROMTOOL"
fi
"$BIN" --version 2>/dev/null | head -1 || true

echo "==> User + dirs"
id prometheus >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin prometheus
mkdir -p "$DATA" /etc/prometheus "$RULES_DIR"
chown -R prometheus:prometheus "$DATA"

echo "==> Config $CONF"
# Base scrape config only. Mirrors templates/prometheus.yml.tmpl; the optional
# dnscollector job is harmless if that receiver isn't installed (just shows down).
# This script owns only global + scrape_configs; every other top-level section
# (rule_files/alerting from install_alertmanager.sh, remote_write, ...) is
# preserved when refreshing the scrape config.
PRESERVED_ALERTING=""
if [ -f "$CONF" ]; then
  cp -a "$CONF" "${CONF}.bak.$(date +%s)"
  PRESERVED_ALERTING="$(
    awk '
      /^[A-Za-z_][A-Za-z0-9_]*:/ {
        key = $1
        sub(/:.*/, "", key)
        keep = (key != "global" && key != "scrape_configs")
      }
      keep {print}
    ' "$CONF"
  )"
  if [ -n "$PRESERVED_ALERTING" ]; then
    echo "    preserving existing non-scrape sections (rule_files/alerting/...)"
  fi
fi
cat > "$CONF" <<EOF
global:
  scrape_interval: ${SCRAPE_INTERVAL}
  evaluation_interval: ${SCRAPE_INTERVAL}
  external_labels:
    environment: lab
    monitor: dnstap2

scrape_configs:
  - job_name: vector_dnstap
    metrics_path: /metrics
    static_configs:
      - targets: ["${VECTOR_TARGET}"]
        labels:
          source: vector

  - job_name: dnscollector
    metrics_path: /metrics
    static_configs:
      - targets: ["${DNSCOLLECTOR_TARGET}"]
        labels:
          source: dnscollector

  - job_name: prometheus_self
    static_configs:
      - targets: ["localhost:${PORT}"]
EOF
if [ -n "$PRESERVED_ALERTING" ]; then
  printf '\n%s\n' "$PRESERVED_ALERTING" >> "$CONF"
fi
chown -R prometheus:prometheus /etc/prometheus
"$PROMTOOL" check config "$CONF" >/dev/null && echo "    config OK"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  echo "==> systemd unit"
  cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=${BIN} \\
  --config.file=${CONF} \\
  --storage.tsdb.path=${DATA} \\
  --web.listen-address=0.0.0.0:${PORT} \\
  --web.enable-lifecycle
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  echo "==> Firewall (best-effort)"
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi

  echo "==> Enable + start"
  systemctl daemon-reload
  systemctl enable prometheus >/dev/null 2>&1 || true
  systemctl restart prometheus
  for i in $(seq 1 20); do
    code=$(curl -s -m3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/-/ready" 2>/dev/null || true)
    [ "$code" = "200" ] && break; sleep 2
  done
  echo "    /-/ready -> ${code:-down}"
  echo "Prometheus on :${PORT}. Scrapes ${VECTOR_TARGET} (vector) + ${DNSCOLLECTOR_TARGET} (dnscollector)."
  echo "Run install_alertmanager.sh next to add alert rules + Alertmanager wiring."
else
  echo "==> systemd not detected"
  echo "    installed binaries and wrote $CONF, but did not write/start a service."
  echo "    run manually:"
  echo "    $BIN --config.file=$CONF --storage.tsdb.path=$DATA --web.listen-address=0.0.0.0:$PORT --web.enable-lifecycle"
fi
