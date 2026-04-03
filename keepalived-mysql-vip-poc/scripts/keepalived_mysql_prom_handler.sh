#!/bin/bash
# Keepalived notify handler: writes Prometheus textfile metrics for Writer or Reader VIP
# status ok/fail. Labels: cluster, vip, role (writer|reader). Metric value 0=ok, 1=fail.
#
# Usage:
#   /path/to/script --status ok --vip 192.168.88.18 --role writer --cluster NAME [--prom-output-dir DIR]
#
# Options (flags only, no env):
#   --status STATUS   ok or fail (required).
#   --vip IP          Virtual IP address (required).
#   --role ROLE       writer or reader (required).
#   --cluster NAME    Cluster label (required).
#   --prom-output-dir DIR  Directory for .prom file (default: /home/percona/pmm/collectors/textfile-collector/high-resolution).
#
# Output: <prom-output-dir>/keepalived_mysql_<vip>.prom. File mode 0644.

set -o nounset

STATUS=""
VIP=""
ROLE=""
CLUSTER_NAME=""
PROM_OUTPUT_DIR="/home/percona/pmm/collectors/textfile-collector/high-resolution"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)     STATUS="${2:-}"; shift 2 ;;
    --vip)        VIP="${2:-}"; shift 2 ;;
    --role)       ROLE="${2:-}"; shift 2 ;;
    --cluster)    CLUSTER_NAME="${2:-}"; shift 2 ;;
    --prom-output-dir) PROM_OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

ERR="keepalived_mysql_prom_handler"
[[ -z "$STATUS" ]] && { echo "$ERR: error: missing --status" >&2; exit 1; }
[[ "$STATUS" != "ok" && "$STATUS" != "fail" ]] && { echo "$ERR: error: --status must be ok or fail, got: $STATUS" >&2; exit 1; }
[[ -z "$VIP" ]] && { echo "$ERR: error: missing --vip" >&2; exit 1; }
[[ -z "$ROLE" ]] && { echo "$ERR: error: missing --role" >&2; exit 1; }
[[ -z "$CLUSTER_NAME" ]] && { echo "$ERR: error: missing --cluster" >&2; exit 1; }
[[ -z "$PROM_OUTPUT_DIR" ]] && { echo "$ERR: error: missing --prom-output-dir" >&2; exit 1; }

if [[ "$STATUS" == "fail" ]]; then
  VALUE=1
else
  VALUE=0
fi

mkdir -p "$PROM_OUTPUT_DIR" 2>/dev/null || true
[[ -d "$PROM_OUTPUT_DIR" && -w "$PROM_OUTPUT_DIR" ]] || exit 0

OUTPUT_FILE="${PROM_OUTPUT_DIR}/keepalived_mysql_${VIP}.prom"
TS=$(date +%s)

LABELS="cluster=\"$CLUSTER_NAME\",vip=\"$VIP\",role=\"$ROLE\""

{
  echo "# HELP percona_keepalived_mysql Keepalived MySQL VIP status (0=ok, 1=fail)"
  echo "# TYPE percona_keepalived_mysql untyped"
  echo "# HELP percona_keepalived_mysql_last_report_ts Keepalived MySQL VIP last report timestamp"
  echo "# TYPE percona_keepalived_mysql_last_report_ts untyped"
  printf 'percona_keepalived_mysql{%s} %s\n' "$LABELS" "$VALUE"
  printf 'percona_keepalived_mysql_last_report_ts{%s} %s\n' "$LABELS" "$TS"
} > "$OUTPUT_FILE" 2>/dev/null || true
chmod 644 "$OUTPUT_FILE" 2>/dev/null || true
