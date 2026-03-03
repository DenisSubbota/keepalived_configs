#!/bin/bash
# Keepalived notify handler: writes Prometheus textfile metrics for Writer or Reader VIP
# state (MASTER/FAULT). Labels: cluster, vip (IP address), Cluster_Virtual_IP_name (inventory name for this VIP).
# Metric value 0=healthy, 1=failover_error.
#
# Usage:
#   From Keepalived (positionals):  notify_* "/path/to/script"  -> $3=state. Set VIP, CLUSTER_VIRTUAL_IP_NAME, CLUSTER_NAME in env.
#   With flags:  /path/to/script --state MASTER --vip 192.168.88.18 --cluster-virtual-ip-name mysql_writer_vip [--cluster NAME]
#
# Options:
#   --state STATE               MASTER, BACKUP, or FAULT. Required if using flags. Only MASTER/FAULT are written.
#   --vip IP                    Virtual IP address (required). Or set VIP in env.
#   --cluster-virtual-ip-name N Name of the VIP in inventory (required for label). Or set CLUSTER_VIRTUAL_IP_NAME in env.
#   --cluster NAME              Cluster label (default: default). Or set CLUSTER_NAME in env.
#
# Output: PROM_OUTPUT_DIR/keepalived_mysql_<vip_sanitized>.prom. File mode 0644.

set -o nounset

STATE=""
VIP="${VIP:-}"
CLUSTER_VIRTUAL_IP_NAME="${CLUSTER_VIRTUAL_IP_NAME:-}"
CLUSTER_NAME="${CLUSTER_NAME:-default}"
PROM_OUTPUT_DIR="${PROM_OUTPUT_DIR:-/home/percona/pmm/collectors/textfile-collector/high-resolution}"

# Parse flags (if first arg looks like a flag)
if [[ "${1:-}" == --* ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state)                    STATE="${2:-}"; shift 2 ;;
      --vip)                      VIP="${2:-}";   shift 2 ;;
      --cluster-virtual-ip-name)  CLUSTER_VIRTUAL_IP_NAME="${2:-}"; shift 2 ;;
      --cluster)                  CLUSTER_NAME="${2:-}"; shift 2 ;;
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

# Labels: cluster, vip (IP), Cluster_Virtual_IP_name (inventory name for this VIP)
if [[ -n "$CLUSTER_VIRTUAL_IP_NAME" ]]; then
  printf -v LABELS 'cluster="%s",vip="%s",Cluster_Virtual_IP_name="%s"' "$CLUSTER_NAME" "$VIP" "$CLUSTER_VIRTUAL_IP_NAME"
else
  printf -v LABELS 'cluster="%s",vip="%s"' "$CLUSTER_NAME" "$VIP"
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
