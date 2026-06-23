#!/usr/bin/env bash
# install_health_snmp.sh — OPTIONAL: run the system-health collector as a
# persistent systemd service that polls SNMP (or this host) and appends
# Splunk key=value lines to a log the Splunk UF already monitors.
#
#   poc_health_snmp.py --loop -> HEALTH_LOG_PATH -> Splunk UF -> index=mi_dhcp
#   (sourcetype=infoblox:health, source=infoblox:health) -> infoblox_system_health dashboard
#
# This script does NOT touch dnstap. It installs one service. To also add the
# UF monitor for the health file, re-run the UF installer with HEALTH_LOG_PATH:
#   HEALTH_LOG_PATH=/var/log/dnstap-health/health.log sudo -E ./scripts/install_splunk_uf.sh
# (this script prints that reminder at the end).
#
# Modes (auto-selected; override with HEALTH_MODE):
#   fleet   poll every member in HEALTH_TARGETS_FILE via SNMP   (if file set)
#   snmp    poll one HEALTH_TARGET via SNMP                      (if target set)
#   self    collect THIS host's metrics from /proc (no SNMP)    (otherwise)
#
# Tunables (env):
#   HEALTH_TARGETS_FILE  file of host[,community[,member[,profile]]] lines (FLEET — point
#                        it at every DNS server that sends dnstap)
#   HEALTH_TARGET     single SNMP agent host/IP (InfoBlox member or net-snmp host)
#   HEALTH_PROFILE    infoblox (enterprise MIB: CPU/mem/swap + per-service status +
#                     temp + replication) | ucd (generic net-snmp)   (default: infoblox)
#   SNMP_COMMUNITY    SNMPv2c community            (default: public)
#   HEALTH_MEMBER     member/node label in lines   (default: HEALTH_TARGET or hostname)
#   HEALTH_INTERVAL   seconds between polls         (default: 60)
#   HEALTH_LOG_PATH   output log file              (default: /var/log/dnstap-health/health.log)
#   HEALTH_USER       service user                 (default: existing 'dnscollector' or 'root')
#   OID_* / OID_IB_*  override individual OIDs (passed through to the collector)
#
# Usage (RHEL 7.9 POC box, after git pull):
#   # whole fleet of dnstap-sending InfoBlox members:
#   HEALTH_TARGETS_FILE=/etc/dnstap-health/targets.csv SNMP_COMMUNITY=public \
#       sudo -E ./scripts/install_health_snmp.sh
#   # one member:
#   HEALTH_TARGET=172.25.15.234 SNMP_COMMUNITY=public sudo -E ./scripts/install_health_snmp.sh
#   # the collector box itself (no SNMP):
#   HEALTH_MODE=self sudo -E ./scripts/install_health_snmp.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/poc_common.sh"

HEALTH_TARGET="${HEALTH_TARGET-}"
HEALTH_TARGETS_FILE="${HEALTH_TARGETS_FILE-}"
HEALTH_PROFILE="${HEALTH_PROFILE:-infoblox}"   # infoblox (enterprise MIB) | ucd
# mode: fleet (targets file) > snmp (single target) > self
if [ -n "$HEALTH_TARGETS_FILE" ]; then HEALTH_MODE="${HEALTH_MODE:-fleet}"
elif [ -n "$HEALTH_TARGET" ]; then HEALTH_MODE="${HEALTH_MODE:-snmp}"
else HEALTH_MODE="${HEALTH_MODE:-self}"; fi
SNMP_COMMUNITY="${SNMP_COMMUNITY:-public}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"
HEALTH_LOG_PATH="${HEALTH_LOG_PATH:-/var/log/dnstap-health/health.log}"
HEALTH_MEMBER="${HEALTH_MEMBER:-${HEALTH_TARGET:-$(hostname -f 2>/dev/null || hostname)}}"
SVC=dnstap-health
COLLECTOR="$SCRIPT_DIR/poc_health_snmp.py"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo -E)."; exit 1; }
[ -f "$COLLECTOR" ] || { echo "ERROR: $COLLECTOR not found."; exit 1; }

PYBIN="$(find_python "$REPO_DIR")" || { echo "ERROR: no python3 (>=3.6). Set PYTHON=/path."; exit 1; }
echo "==> python: $PYBIN"

need_snmp() {
  command -v snmpget >/dev/null 2>&1 && command -v snmpwalk >/dev/null 2>&1 || {
    echo "ERROR: net-snmp not found. Install it:";
    echo "       sudo yum install -y net-snmp-utils    # RHEL/CentOS"; exit 1; }
}

if [ "$HEALTH_MODE" = "fleet" ]; then
  [ -f "$HEALTH_TARGETS_FILE" ] || { echo "ERROR: HEALTH_TARGETS_FILE '$HEALTH_TARGETS_FILE' not found."; exit 1; }
  need_snmp
  SRC_ARGS="--targets-file $HEALTH_TARGETS_FILE --community $SNMP_COMMUNITY --profile $HEALTH_PROFILE"
  echo "==> mode: FLEET from $HEALTH_TARGETS_FILE (default profile: $HEALTH_PROFILE)"
elif [ "$HEALTH_MODE" = "snmp" ]; then
  [ -n "$HEALTH_TARGET" ] || { echo "ERROR: HEALTH_MODE=snmp needs HEALTH_TARGET=<host>."; exit 1; }
  need_snmp
  SRC_ARGS="--target $HEALTH_TARGET --community $SNMP_COMMUNITY --member $HEALTH_MEMBER --profile $HEALTH_PROFILE"
  echo "==> mode: SNMP poll of $HEALTH_TARGET ($HEALTH_PROFILE MIB) as '$HEALTH_MEMBER'"
else
  SRC_ARGS="--self --member $HEALTH_MEMBER"
  echo "==> mode: self (/proc) as '$HEALTH_MEMBER'"
fi

# service user: reuse dnscollector if present, else root (no new user needed).
if [ -n "${HEALTH_USER:-}" ]; then
  RUN_USER="$HEALTH_USER"
elif id dnscollector >/dev/null 2>&1; then
  RUN_USER="dnscollector"
else
  RUN_USER="root"
fi
echo "==> service user: $RUN_USER"

# output dir, writable by the service user
mkdir -p "$(dirname "$HEALTH_LOG_PATH")"
touch "$HEALTH_LOG_PATH"
chown "$RUN_USER":"$RUN_USER" "$(dirname "$HEALTH_LOG_PATH")" "$HEALTH_LOG_PATH" 2>/dev/null || true

# pass through any OID overrides present in the environment
OID_ENV=""
for v in $(env | grep -oE '^(OID_[A-Z_]+)=' | tr -d '='); do
  OID_ENV="$OID_ENV Environment=$v=${!v}"
done

UNIT=/etc/systemd/system/${SVC}.service
echo "==> writing $UNIT"
{
  echo "[Unit]"
  echo "Description=DNSTAP2 system-health collector (SNMP -> Splunk key=value)"
  echo "After=network-online.target"
  echo "Wants=network-online.target"
  echo
  echo "[Service]"
  echo "Type=simple"
  echo "User=${RUN_USER}"
  echo "Environment=SNMP_COMMUNITY=${SNMP_COMMUNITY}"
  for e in $OID_ENV; do echo "$e"; done
  echo "ExecStart=${PYBIN} ${COLLECTOR} ${SRC_ARGS} --loop ${HEALTH_INTERVAL} --out ${HEALTH_LOG_PATH}"
  echo "Restart=always"
  echo "RestartSec=10"
  echo
  echo "[Install]"
  echo "WantedBy=multi-user.target"
} > "$UNIT"

systemctl daemon-reload
systemctl reset-failed "$SVC" >/dev/null 2>&1 || true
systemctl enable "$SVC" >/dev/null 2>&1 || true
systemctl restart "$SVC"
sleep "$(( HEALTH_INTERVAL < 4 ? HEALTH_INTERVAL : 4 ))"

echo
echo "==> status"
systemctl is-active "$SVC" && echo "    ${SVC}: active" || echo "    ${SVC}: NOT active (see: journalctl -u ${SVC})"
echo "==> latest health line:"
tail -1 "$HEALTH_LOG_PATH" 2>/dev/null | sed 's/^/    /' || echo "    (no line yet — wait one interval)"

cat <<EOF

DONE. The collector writes ${HEALTH_LOG_PATH} every ${HEALTH_INTERVAL}s.

NEXT — make the Splunk UF ship it (one time), then it flows automatically:
  HEALTH_LOG_PATH=${HEALTH_LOG_PATH} sudo -E ./scripts/install_splunk_uf.sh

Splunk check:
  index=mi_dhcp sourcetype="infoblox:health" | stats latest(health_status) by member
Dashboard: import splunk/infoblox_system_health.xml
EOF
