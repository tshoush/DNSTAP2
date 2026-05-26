#!/usr/bin/env bash
# install_alertmanager.sh — install Prometheus Alertmanager on RHEL/CentOS 7+,
# load dnstap alerting rules into Prometheus, and wire Prometheus -> Alertmanager.
# Static Go binary — works on glibc 2.17 (RHEL 7).
#
# Rules cover: receiver down, stream gone silent, NXDOMAIN/SERVFAIL spikes, and a
# DNS-tunneling heuristic (TXT/NULL/ANY volume). Thresholds are lab defaults —
# tune in /etc/prometheus/rules/dnstap-alerts.yml.
#
# Usage: sudo ./install_alertmanager.sh
set -euo pipefail

AM_VERSION="${AM_VERSION:-0.27.0}"
PORT="${PORT:-9093}"
BIN=/usr/local/bin/alertmanager
PROM_YML="${PROM_YML:-/etc/prometheus/prometheus.yml}"
RULES_DIR=/etc/prometheus/rules

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)."; exit 1; }
case "$(uname -m)" in x86_64) A=amd64;; aarch64) A=arm64;; *) echo "unsupported arch"; exit 1;; esac

echo "==> Installing Alertmanager ${AM_VERSION} (${A})"
if [ -x "$BIN" ] && "$BIN" --version 2>&1 | grep -q "$AM_VERSION"; then
  echo "    already installed, skipping download"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  URL="https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-${A}.tar.gz"
  echo "    downloading $URL"
  curl -fSL --retry 3 -o "$TMP/am.tgz" "$URL"
  tar -xzf "$TMP/am.tgz" -C "$TMP"
  install -m 0755 "$TMP/alertmanager-${AM_VERSION}.linux-${A}/alertmanager" "$BIN"
  install -m 0755 "$TMP/alertmanager-${AM_VERSION}.linux-${A}/amtool" /usr/local/bin/amtool 2>/dev/null || true
fi

echo "==> User + dirs"
id alertmanager >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin alertmanager
id prometheus  >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin prometheus
mkdir -p /etc/alertmanager /var/lib/alertmanager "$RULES_DIR"
chown -R alertmanager:alertmanager /var/lib/alertmanager

echo "==> Alertmanager config (lab: single default receiver; add email/slack as needed)"
cat > /etc/alertmanager/alertmanager.yml <<'EOF'
global:
  resolve_timeout: 5m
route:
  receiver: default
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
receivers:
  - name: default
EOF

echo "==> dnstap alert rules"
cat > "$RULES_DIR/dnstap-alerts.yml" <<'EOF'
groups:
  - name: dnstap
    rules:
      - alert: DnstapReceiverDown
        expr: up{job="vector_dnstap"} == 0
        for: 2m
        labels: {severity: critical}
        annotations:
          summary: "Vector dnstap exporter is down"
          description: "Prometheus cannot scrape the Vector dnstap metrics endpoint."
      - alert: DnstapStreamSilent
        expr: sum(rate(vector_component_received_events_total{component_id="dnstap_in"}[10m])) == 0
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "No dnstap events received for 10m"
          description: "The NIOS member may have stopped streaming dnstap, or the link is down."
      - alert: HighNXDOMAINRate
        expr: sum(rate(dnstap_responses_total{rcode="NXDomain"}[5m])) > 20
        for: 5m
        labels: {severity: warning}
        annotations:
          summary: "Elevated NXDOMAIN rate ({{ $value | printf \"%.1f\" }}/s)"
          description: "Sustained NXDOMAIN spike — possible DGA/malware or misconfiguration."
      - alert: HighSERVFAILRate
        expr: sum(rate(dnstap_responses_total{rcode="ServFail"}[5m])) > 5
        for: 5m
        labels: {severity: warning}
        annotations:
          summary: "Elevated SERVFAIL rate ({{ $value | printf \"%.1f\" }}/s)"
          description: "Resolver/upstream errors or capacity issues."
      - alert: PossibleDNSTunneling
        expr: sum(rate(dnstap_queries_total{qtype=~"TXT|NULL|ANY"}[5m])) > 10
        for: 5m
        labels: {severity: warning}
        annotations:
          summary: "High TXT/NULL/ANY query volume ({{ $value | printf \"%.1f\" }}/s)"
          description: "Unusual record-type volume — possible DNS tunneling/exfiltration. Pivot to events in Grafana/Loki to inspect qnames."
EOF
chown -R prometheus:prometheus "$RULES_DIR" 2>/dev/null || true

echo "==> Wire Prometheus -> rules + Alertmanager (idempotent)"
if ! grep -q "alertmanagers" "$PROM_YML"; then
  cp "$PROM_YML" "${PROM_YML}.bak.$(date +%s)"
  cat >> "$PROM_YML" <<EOF

rule_files:
  - ${RULES_DIR}/*.yml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:${PORT}']
EOF
  echo "    appended rule_files + alerting to $PROM_YML"
else
  echo "    Prometheus already wired to Alertmanager"
fi

echo "==> systemd unit"
cat > /etc/systemd/system/alertmanager.service <<EOF
[Unit]
Description=Prometheus Alertmanager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=alertmanager
Group=alertmanager
ExecStart=${BIN} --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager --web.listen-address=:${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Firewall (best-effort)"
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null || true
  firewall-cmd --reload >/dev/null || true
fi

echo "==> Start Alertmanager + reload Prometheus"
# validate rules before reloading Prometheus
if command -v promtool >/dev/null 2>&1; then promtool check rules "$RULES_DIR"/*.yml || { echo "rule check failed"; exit 1; }; fi
systemctl daemon-reload
systemctl enable alertmanager >/dev/null 2>&1 || true
systemctl restart alertmanager
systemctl reload prometheus 2>/dev/null || systemctl restart prometheus
sleep 4
for i in $(seq 1 15); do
  code=$(curl -s -m3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/-/healthy" 2>/dev/null || true)
  [ "$code" = "200" ] && break; sleep 2
done
echo "    alertmanager /-/healthy -> ${code:-down}"
echo "Alertmanager on :${PORT}. Prometheus rules: $RULES_DIR/dnstap-alerts.yml"
echo "Add notifiers (email/Slack/webhook) under 'receivers' in /etc/alertmanager/alertmanager.yml."
