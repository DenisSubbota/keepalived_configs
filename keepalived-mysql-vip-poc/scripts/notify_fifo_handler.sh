#!/bin/bash
# Keepalived FIFO notify handler: writes Prometheus textfile metrics for MySQL VIPs.
# Reads VRRP state/priority changes from the FIFO (path passed by keepalived as the last argument).
#
# Usage:
#   /path/to/script --cluster NAME --writer-vip IP --reader-vip IP [--priority-threshold N] [--prom-output-dir DIR] <FIFO_PATH>

set -o nounset

CLUSTER_NAME=""
WRITER_VIP=""
READER_VIP=""
PRIORITY_THRESHOLD=10
FIFO_PATH=""
PROM_OUTPUT_DIR="/home/percona/pmm/collectors/textfile-collector/high-resolution"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)            CLUSTER_NAME="${2:-}";       shift 2 ;;
    --writer-vip)         WRITER_VIP="${2:-}";         shift 2 ;;
    --reader-vip)         READER_VIP="${2:-}";         shift 2 ;;
    --priority-threshold) PRIORITY_THRESHOLD="${2:-}"; shift 2 ;;
    --prom-output-dir)    PROM_OUTPUT_DIR="${2:-}";    shift 2 ;;
    *) FIFO_PATH="$1"; shift ;;
  esac
done

ERR="notify_fifo_handler"
[[ -z "$CLUSTER_NAME" ]] && { echo "$ERR: error: missing --cluster" >&2; exit 1; }
[[ -z "$WRITER_VIP" ]]   && { echo "$ERR: error: missing --writer-vip" >&2; exit 1; }
[[ -z "$READER_VIP" ]]   && { echo "$ERR: error: missing --reader-vip" >&2; exit 1; }
[[ -z "$FIFO_PATH" ]]    && { echo "$ERR: error: no FIFO path (keepalived passes it as last argument)" >&2; exit 1; }

mkdir -p "$PROM_OUTPUT_DIR" 2>/dev/null || true
[[ -d "$PROM_OUTPUT_DIR" && -w "$PROM_OUTPUT_DIR" ]] || exit 0

write_prom() {
  local vip="$1" role="$2" value="$3"
  local labels="cluster=\"$CLUSTER_NAME\",vip=\"$vip\",role=\"$role\""
  local ts
  ts=$(date +%s)
  local output_file="${PROM_OUTPUT_DIR}/keepalived_mysql_${vip}.prom"
  {
    echo "# HELP percona_keepalived_mysql Keepalived MySQL VIP status (0=ok, 1=fail)"
    echo "# TYPE percona_keepalived_mysql untyped"
    echo "# HELP percona_keepalived_mysql_last_report_ts Keepalived MySQL VIP last report timestamp"
    echo "# TYPE percona_keepalived_mysql_last_report_ts untyped"
    printf 'percona_keepalived_mysql{%s} %s\n' "$labels" "$value"
    printf 'percona_keepalived_mysql_last_report_ts{%s} %s\n' "$labels" "$ts"
  } > "$output_file" 2>/dev/null || true
  chmod 644 "$output_file" 2>/dev/null || true
}

while read -r LINE; do
  [[ "$LINE" =~ ^INSTANCE ]] || continue

  LINE_CLEAN="${LINE//\"/}"
  read -r _ INST_NAME STATE PRIORITY <<< "$LINE_CLEAN"

  [[ -z "${INST_NAME:-}" || -z "${STATE:-}" || -z "${PRIORITY:-}" ]] && continue

  case "$INST_NAME" in
    VI_MYSQL_WRITER)
      case "$STATE" in
        MASTER|MASTER_PRIORITY)
          if [[ "$PRIORITY" -ge "$PRIORITY_THRESHOLD" ]]; then
            write_prom "$WRITER_VIP" "writer" 0
          else
            write_prom "$WRITER_VIP" "writer" 1
          fi
          ;;
        *)
          write_prom "$WRITER_VIP" "writer" 1
          ;;
      esac
      ;;
    VI_MYSQL_READER)
      case "$STATE" in
        MASTER|MASTER_PRIORITY)
          if [[ "$PRIORITY" -ge "$PRIORITY_THRESHOLD" ]]; then
            write_prom "$READER_VIP" "reader" 0
          else
            write_prom "$READER_VIP" "reader" 1
          fi
          ;;
        *)
          write_prom "$READER_VIP" "reader" 1
          ;;
      esac
      ;;
  esac
done < "$FIFO_PATH"
