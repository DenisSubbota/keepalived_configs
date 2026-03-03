#!/bin/bash
# Keepalived notify handler: writes Prometheus textfile metrics for Writer or Reader VIP
# state (MASTER/FAULT). Labels: cluster, vip, role (writer|reader). Metric value 0=healthy, 1=failover_error.
#
# Usage:
#   With flags:  /path/to/script --state MASTER --vip 192.168.88.18 --role writer [--cluster NAME]
#
# Options:
#   --state STATE  MASTER, BACKUP, or FAULT. Required if using flags. Only MASTER/FAULT are written.
#   --vip IP       Virtual IP address (required). Or set VIP in env.
#   --role ROLE    writer or reader (required for label). Or set ROLE in env.
#   --cluster NAME Cluster label (default: default). Or set CLUSTER_NAME in env.
#
# Output: PROM_OUTPUT_DIR/keepalived_mysql_<vip_sanitized>.prom. File mode 0644.

set -o nounset

STATE=""
VIP="${VIP:-}"
ROLE="${ROLE:-}"
CLUSTER_NAME="${CLUSTER_NAME:-default}"
PROM_OUTPUT_DIR="${PROM_OUTPUT_DIR:-/home/percona/pmm/collectors/textfile-collector/high-resolution}"

# Parse flags (if first arg looks like a flag)
if [[ "${1:-}" == --* ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state)   STATE="${2:-}"; shift 2 ;;
      --vip)     VIP="${2:-}";   shift 2 ;;
      --role)    ROLE="${2:-}";  shift 2 ;;
      --cluster) CLUSTER_NAME="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
else
  STATE="${3:-}"
fi

[[ -z "$STATE" ]] && exit 0
[[ "$STATE" != "MASTER" && "$STATE" != "FAULT" ]] && exit 0

if [[ "$STATE" == "FAULT" ]]; then
  VALUE=1
else
  VALUE=0
fi

[[ -z "$VIP" ]] && exit 0

mkdir -p "$PROM_OUTPUT_DIR" 2>/dev/null || true
[[ -d "$PROM_OUTPUT_DIR" && -w "$PROM_OUTPUT_DIR" ]] || exit 0

# One file per VIP (dots -> underscores for filename)
VIP_SAFE="${VIP//./_}"
OUTPUT_FILE="${PROM_OUTPUT_DIR}/keepalived_mysql_${VIP_SAFE}.prom"
TS=$(date +%s)

# role (writer/reader) optional but informative
if [[ -n "$ROLE" ]]; then
  LABELS="cluster=\"$CLUSTER_NAME\",vip=\"$VIP\",role=\"$ROLE\""
else
  LABELS="cluster=\"$CLUSTER_NAME\",vip=\"$VIP\""
fi

{
  echo "# HELP gas_keepalived_mysql Keepalived MySQL VIP state"
  echo "# TYPE gas_keepalived_mysql untyped"
  echo "# HELP gas_keepalived_mysql_last_report_ts Keepalived MySQL VIP last report timestamp"
  echo "# TYPE gas_keepalived_mysql_last_report_ts untyped"
  printf 'gas_keepalived_mysql{%s} %s\n' "$LABELS" "$VALUE"
  printf 'gas_keepalived_mysql_last_report_ts{%s} %s\n' "$LABELS" "$TS"
} > "$OUTPUT_FILE" 2>/dev/null || true
chmod 644 "$OUTPUT_FILE" 2>/dev/null || true
