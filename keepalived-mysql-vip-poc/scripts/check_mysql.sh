#!/bin/bash
# Unified MySQL health check for Keepalived (MySQL 5.7 / 8.0 / 8.4)
#
# Modes (exactly one required):
#   --primary           Node must be writable primary (read_only=0, not replica)
#   --replica           Node must be healthy replica (read_only=1, IO/SQL running, lag under --max-lag)
#   --writer-or-reader  Node must be either healthy primary OR healthy replica (for shared VIP)
#
# Options (all optional, no env vars):
#   --defaults-file PATH  MySQL client option file (same as mysql --defaults-file) [default: /home/percona/.my.cnf]
#   --mysql-bin PATH      mysql binary [default: mysql]
#   --max-lag N           Default max replication lag (seconds) for --replica [default: 300]
#   --no-vip-file PATH    If this file exists, exit 255 (do not claim VIP) [default: /etc/keepalived/no_vip]
#   --log-dir DIR         Log directory [default: /var/log/percona]
#   --log-max-size N      Rotate when log exceeds N bytes [default: 52428800 = 50 MiB]
#   --log-rotate-keep N   Keep N rotated log files [default: 7]
#   --allow-primary-as-replica  Allow primary even if node is configured as replica (--primary only)
#
# Exit: 0 = check passed, 1 = check failed, 255 = do not claim VIP (no_vip file present)

set -o nounset

# --- Defaults (no env vars) ---
MYSQL_CNF_PATH="/home/percona/.my.cnf"
MYSQL_BIN="mysql"
MAX_LAG_SECONDS="300"
NO_VIP_FILE="/etc/keepalived/no_vip"
LOG_DIR="/var/log/percona"
LOG_MAX_SIZE="52428800"
LOG_ROTATE_KEEP="7"
ALLOW_PRIMARY_AS_REPLICA="0"

MODE=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary)
      MODE="primary"
      shift
      ;;
    --replica)
      MODE="replica"
      shift
      ;;
    --max-lag)
      shift
      if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        MAX_LAG_SECONDS="$1"
      fi
      shift
      ;;
    --writer-or-reader)
      MODE="writer_or_reader"
      shift
      ;;
    --defaults-file)
      shift
      MYSQL_CNF_PATH="${1:-}"
      shift
      ;;
    --mysql-bin)
      shift
      MYSQL_BIN="${1:-mysql}"
      shift
      ;;
    --no-vip-file)
      shift
      NO_VIP_FILE="${1:-/etc/keepalived/no_vip}"
      shift
      ;;
    --log-dir)
      shift
      LOG_DIR="${1:-/var/log/percona}"
      shift
      ;;
    --log-max-size)
      shift
      if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        LOG_MAX_SIZE="$1"
      fi
      shift
      ;;
    --log-rotate-keep)
      shift
      if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        LOG_ROTATE_KEEP="$1"
      fi
      shift
      ;;
    --allow-primary-as-replica)
      ALLOW_PRIMARY_AS_REPLICA="1"
      shift
      ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

[[ -z "$MODE" ]] && echo "Usage: $0 --primary | --replica | --writer-or-reader [options...]" >&2 && exit 1

# Derive log file path after --log-dir may have been set
LOG_FILE="${LOG_DIR}/keepalived_check_mysql.log"

# --- Logging ---
rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null) || return 0
  [[ -n "$size" && "$size" -ge "$LOG_MAX_SIZE" ]] || return 0
  local i
  rm -f "${LOG_FILE}.${LOG_ROTATE_KEEP}" 2>/dev/null || true
  for (( i=LOG_ROTATE_KEEP-1; i>=1; i-- )); do
    [[ -f "${LOG_FILE}.$i" ]] && mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
  done
  mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 644 "$LOG_FILE" 2>/dev/null || true
}

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if [[ -d "$LOG_DIR" && -w "$LOG_DIR" ]]; then
    rotate_log
    echo "$(date -Iseconds) [$MODE] $*" >> "$LOG_FILE" 2>/dev/null || true
    chmod 644 "$LOG_FILE" 2>/dev/null || true
  fi
}

# --- Shared: no_vip and config ---
if [[ -e "$NO_VIP_FILE" ]]; then
  log "no_vip file present, not claiming VIP"
  exit 255
fi

if [[ ! -r "${MYSQL_CNF_PATH:-}" ]]; then
  log "MySQL config unreadable: ${MYSQL_CNF_PATH:-<unset>}"
  exit 1
fi

MYSQL_ARGS=(--defaults-file="$MYSQL_CNF_PATH" --connect-timeout=3 --batch --skip-column-names -s -N)
# Vertical output (\G) must keep "Field: Value" lines for parsing; do not use -s -N --skip-column-names
MYSQL_ARGS_VERTICAL=(--defaults-file="$MYSQL_CNF_PATH" --connect-timeout=3 --batch)
run_mysql() {
  "$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "$1" 2>/dev/null
}
run_mysql_vertical() {
  "$MYSQL_BIN" "${MYSQL_ARGS_VERTICAL[@]}" -e "$1" 2>/dev/null
}

# --- Check: primary (writer) ---
# Success: read_only=0, and (if ALLOW_PRIMARY_AS_REPLICA≠1) not configured as replica.
check_primary() {
  local ro
  ro="$(run_mysql "SELECT @@global.read_only;" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')"
  if [[ "$ro" != "0" ]]; then
    log "primary failed: read_only=${ro:-<empty>} (must be 0)"
    return 1
  fi

  if [[ "$ALLOW_PRIMARY_AS_REPLICA" != "1" ]]; then
    local replica_status
    replica_status="$(run_mysql "SHOW REPLICA STATUS")"
    [[ -z "$replica_status" ]] && replica_status="$(run_mysql "SHOW SLAVE STATUS" || true)"
    if [[ -n "$replica_status" ]]; then
      log "primary failed: node is replica, cannot be primary"
      return 1
    fi
  fi

  log "primary OK: node is healthy primary"
  return 0
}

# --- Check: replica (reader) ---
# Success: read_only=1, IO and SQL running, lag < LAG_SECONDS.
check_replica() {
  local status_output io_running sql_running lag_val lag ro

  status_output="$(run_mysql_vertical "SHOW REPLICA STATUS\\G")"
  [[ -z "$status_output" ]] && status_output="$(run_mysql_vertical "SHOW SLAVE STATUS\\G" || true)"

  if [[ -z "$status_output" ]]; then
    log "replica failed: no replication status or MySQL unreachable"
    return 1
  fi

  io_running="$(echo "$status_output" | awk -F': ' '/Replica_IO_Running:|Slave_IO_Running:/ {print $2; exit}')"
  sql_running="$(echo "$status_output" | awk -F': ' '/Replica_SQL_Running:|Slave_SQL_Running:/ {print $2; exit}')"
  lag_val="$(echo "$status_output" | awk -F': ' '/Seconds_Behind_Source:|Seconds_Behind_Master:/ {print $2; exit}')"

  io_running="${io_running:-No}"
  sql_running="${sql_running:-No}"
  case "$lag_val" in
    ""|NULL|null) lag=999999 ;;
    *)            lag="$lag_val" ;;
  esac

  ro="$(run_mysql "SELECT @@global.read_only;" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')"

  if [[ "$io_running" == "Yes" && "$sql_running" == "Yes" && "$lag" -lt "$MAX_LAG_SECONDS" && "$ro" == "1" ]]; then
    log "replica OK: node is healthy replica (lag=${lag})"
    return 0
  fi
  log "replica failed: io=$io_running sql=$sql_running lag=${lag:-?} read_only=${ro:-<empty>} (need Yes/Yes/<${MAX_LAG_SECONDS}/1)"
  return 1
}

# --- Main: run selected mode ---
case "$MODE" in
  primary)
    check_primary
    exit $?
    ;;
  replica)
    check_replica
    exit $?
    ;;
  writer_or_reader)
    if check_primary; then
      exit 0
    fi
    if check_replica; then
      exit 0
    fi
    log "writer_or_reader failed: node is neither healthy primary nor healthy replica"
    exit 1
    ;;
  *)
    echo "Invalid mode: $MODE" >&2
    exit 1
    ;;
esac
