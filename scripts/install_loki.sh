#!/usr/bin/env bash
# install_loki.sh — install Grafana Loki (single-binary, filesystem storage) on
# RHEL/CentOS 7+. Receives decoded dnstap events from Vector's loki sink and
# makes them searchable in Grafana (Loki datasource). Static Go binary — works
# on glibc 2.17 (RHEL 7).
#
# Usage: sudo ./install_loki.sh
set -euo pipefail

LOKI_VERSION="${LOKI_VERSION:-3.4.2}"
PORT="${PORT:-3100}"
BIN=/usr/local/bin/loki
DATA=/var/lib/loki
CONF=/etc/loki/loki-config.yaml

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)."; exit 1; }
case "$(uname -m)" in x86_64) A=amd64;; aarch64) A=arm64;; *) echo "unsupported arch"; exit 1;; esac

echo "==> Installing Loki ${LOKI_VERSION} (${A})"
if [ -x "$BIN" ] && "$BIN" --version 2>/dev/null | grep -q "$LOKI_VERSION"; then
  echo "    already installed, skipping download"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-${A}.zip"
  echo "    downloading $URL"
  curl -fSL --retry 3 -o "$TMP/loki.zip" "$URL"
  if command -v unzip >/dev/null 2>&1; then unzip -o -q "$TMP/loki.zip" -d "$TMP";
  else python -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMP/loki.zip" "$TMP"; fi
  install -m 0755 "$TMP/loki-linux-${A}" "$BIN"
fi
"$BIN" --version 2>/dev/null | head -1 || true

echo "==> User + dirs"
id loki >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin loki
mkdir -p "$DATA/chunks" "$DATA/rules" "$DATA/tsdb-index" /etc/loki
chown -R loki:loki "$DATA"

echo "==> Config $CONF"
cat > "$CONF" <<EOF
auth_enabled: false
server:
  http_listen_port: ${PORT}
  grpc_listen_port: 9096
  log_level: warn
common:
  instance_addr: 127.0.0.1
  path_prefix: ${DATA}
  storage:
    filesystem:
      chunks_directory: ${DATA}/chunks
      rules_directory: ${DATA}/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
storage_config:
  tsdb_shipper:
    active_index_directory: ${DATA}/tsdb-index
    cache_location: ${DATA}/tsdb-cache
limits_config:
  reject_old_samples: false
  allow_structured_metadata: true
  volume_enabled: true
analytics:
  reporting_enabled: false
EOF
chown loki:loki "$CONF"

echo "==> systemd unit"
cat > /etc/systemd/system/loki.service <<EOF
[Unit]
Description=Grafana Loki
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=loki
Group=loki
ExecStart=${BIN} -config.file=${CONF}
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
systemctl enable loki >/dev/null 2>&1 || true
systemctl restart loki
for i in $(seq 1 20); do
  code=$(curl -s -m3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/ready" 2>/dev/null || true)
  [ "$code" = "200" ] && break; sleep 2
done
echo "    /ready -> ${code:-down}"
echo "Loki on :${PORT}. Add a Vector loki sink pointing at http://<this-host>:${PORT}."
