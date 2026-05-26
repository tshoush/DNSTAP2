#!/usr/bin/env bash
# install_grafana.sh — install Grafana (OSS) on RHEL/CentOS 7+ and provision a
# Prometheus datasource + a dnstap DNS dashboard. Pairs with the Prometheus that
# scrapes the Vector dnstap exporter (:9598).
#
# Grafana 10.4.x is the last line that supports RHEL 7 / glibc 2.17; v11 needs
# glibc 2.28+. Override with GRAFANA_VERSION if your host is newer.
#
# Usage: sudo ./install_grafana.sh
set -euo pipefail

GRAFANA_VERSION="${GRAFANA_VERSION:-10.4.2}"
PORT="${PORT:-3000}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"   # provisioned too; harmless if Loki absent
HOME_DIR=/opt/grafana
DATA_DIR=/var/lib/grafana
LOG_DIR=/var/log/grafana
PROV="$HOME_DIR/conf/provisioning"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)."; exit 1; }
case "$(uname -m)" in x86_64) A=amd64;; aarch64) A=arm64;; *) echo "unsupported arch"; exit 1;; esac

echo "==> Installing Grafana ${GRAFANA_VERSION} (${A})"
if [ -x "$HOME_DIR/bin/grafana-server" ] && "$HOME_DIR/bin/grafana-server" -v 2>/dev/null | grep -q "$GRAFANA_VERSION"; then
  echo "    already installed, skipping download"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  URL="https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-${A}.tar.gz"
  echo "    downloading $URL"
  curl -fSL --retry 3 -o "$TMP/g.tgz" "$URL"
  tar -xzf "$TMP/g.tgz" -C "$TMP"
  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR"
  cp -a "$TMP"/grafana-*/. "$HOME_DIR"/
fi
"$HOME_DIR/bin/grafana-server" -v 2>/dev/null | head -1 || true

echo "==> User + dirs"
id grafana >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin grafana
mkdir -p "$DATA_DIR" "$LOG_DIR" "$PROV/datasources" "$PROV/dashboards" "$PROV/dashboards/json"
chown -R grafana:grafana "$DATA_DIR" "$LOG_DIR" "$HOME_DIR"

echo "==> Config (custom.ini)"
cat > "$HOME_DIR/conf/custom.ini" <<EOF
[paths]
data = ${DATA_DIR}
logs = ${LOG_DIR}
provisioning = ${PROV}
[server]
http_port = ${PORT}
[security]
admin_user = admin
admin_password = admin
[auth.anonymous]
enabled = true
org_role = Viewer
[analytics]
reporting_enabled = false
check_for_updates = false
EOF

echo "==> Datasources (Prometheus + Loki)"
cat > "$PROV/datasources/datasources.yaml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: ${PROM_URL}
    isDefault: true
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: ${LOKI_URL}
EOF

echo "==> Dashboard provider"
cat > "$PROV/dashboards/dashboards.yaml" <<'EOF'
apiVersion: 1
providers:
  - name: dnstap
    orgId: 1
    folder: DNS
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /opt/grafana/conf/provisioning/dashboards/json
EOF

echo "==> DNS dashboard JSON"
cat > "$PROV/dashboards/json/dnstap-overview.json" <<'EOF'
{
  "uid": "dnstap-overview",
  "title": "DNS / dnstap Overview",
  "tags": ["dnstap", "dns", "infoblox"],
  "timezone": "browser",
  "schemaVersion": 39,
  "refresh": "10s",
  "time": {"from": "now-1h", "to": "now"},
  "templating": {"list": []},
  "panels": [
    {
      "id": 1, "type": "timeseries", "title": "DNS queries/s by type",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
      "fieldConfig": {"defaults": {"unit": "qps", "custom": {"drawStyle": "line", "fillOpacity": 20, "stacking": {"mode": "normal"}}}, "overrides": []},
      "targets": [{"refId": "A", "expr": "sum by (qtype) (rate(dnstap_queries_total[5m]))", "legendFormat": "{{qtype}}"}]
    },
    {
      "id": 2, "type": "timeseries", "title": "DNS responses/s by rcode",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
      "fieldConfig": {"defaults": {"unit": "qps", "custom": {"drawStyle": "line", "fillOpacity": 20, "stacking": {"mode": "normal"}}}, "overrides": []},
      "targets": [{"refId": "A", "expr": "sum by (rcode) (rate(dnstap_responses_total[5m]))", "legendFormat": "{{rcode}}"}]
    },
    {
      "id": 3, "type": "stat", "title": "NXDOMAIN responses/s",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 6, "w": 6, "x": 0, "y": 8},
      "fieldConfig": {"defaults": {"unit": "qps", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": 5}, {"color": "red", "value": 20}]}}, "overrides": []},
      "targets": [{"refId": "A", "expr": "sum(rate(dnstap_responses_total{rcode=\"NXDomain\"}[5m]))"}]
    },
    {
      "id": 4, "type": "stat", "title": "Total queries seen",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 6, "w": 6, "x": 6, "y": 8},
      "fieldConfig": {"defaults": {"unit": "short"}, "overrides": []},
      "targets": [{"refId": "A", "expr": "sum(dnstap_queries_total)"}]
    },
    {
      "id": 5, "type": "timeseries", "title": "dnstap events received/s (pipeline health)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"h": 6, "w": 12, "x": 12, "y": 8},
      "fieldConfig": {"defaults": {"unit": "eps", "custom": {"drawStyle": "line", "fillOpacity": 10}}, "overrides": []},
      "targets": [{"refId": "A", "expr": "sum(rate(vector_component_received_events_total{component_id=\"dnstap_in\"}[1m]))", "legendFormat": "events/s"}]
    }
  ]
}
EOF
chown -R grafana:grafana "$HOME_DIR"

echo "==> systemd unit"
cat > /etc/systemd/system/grafana.service <<EOF
[Unit]
Description=Grafana
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=grafana
Group=grafana
WorkingDirectory=${HOME_DIR}
ExecStart=${HOME_DIR}/bin/grafana-server --homepath=${HOME_DIR} --config=${HOME_DIR}/conf/custom.ini
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
systemctl enable grafana >/dev/null 2>&1 || true
systemctl restart grafana
for i in $(seq 1 20); do
  code=$(curl -s -m3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || true)
  [ "$code" = "200" ] && break; sleep 2
done
echo "    /api/health -> ${code:-down}"
echo
echo "Grafana: http://<this-host>:${PORT}  (admin/admin; anonymous viewer enabled)"
echo "Dashboard: 'DNS / dnstap Overview' in the DNS folder."
