#!/bin/bash
# Compatibilite with MySQL 5.7 / 8.0 / 8.4
# Node considered as healty Reader if next conditions are true:
# - Node is read-only: @@global.read_only=1
# - Node is Healthy replica: SQL and IO threads running (`Yes`) 
# - Node has healthy replication lag: replication lag is below threshold: `Seconds_Behind_Source` / `Seconds_Behind_Master` < `MAX_LAG_SECONDS`
# Otherwise node is considered as unhealthy Reader

set -o nounset

# Client option file path only (same format for MySQL/MariaDB/PXC/Percona). Must contain [client] with user, password, host, port/socket.
MYSQL_CNF_PATH=${MYSQL_CNF_PATH:-/home/percona/.my.cnf}
MYSQL_BIN=${MYSQL_BIN:-mysql}
MAX_LAG_SECONDS=${MAX_LAG_SECONDS:-300}
NO_VIP_FILE=${NO_VIP_FILE:-/etc/keepalived/no_vip}
LOG_DIR=${LOG_DIR:-/var/log/percona}
LOG_FILE="${LOG_DIR}/keepalived_check_mysql_reader.log"
LOG_MAX_SIZE=${LOG_MAX_SIZE:-1048576}
LOG_ROTATE_KEEP=${LOG_ROTATE_KEEP:-7}

# Rotate log file if it exceeds LOG_MAX_SIZE (default 1MB); keep LOG_ROTATE_KEEP rotated copies (.1, .2, ...)
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

# Log: create dir, rotate if needed, append line, set 644
log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if [[ -d "$LOG_DIR" && -w "$LOG_DIR" ]]; then
    rotate_log
    echo "$(date -Iseconds) $*" >> "$LOG_FILE" 2>/dev/null || true
    chmod 644 "$LOG_FILE" 2>/dev/null || true
  fi
}

if [[ -e "$NO_VIP_FILE" ]]; then
  log "no_vip file present, not claiming reader VIP"
  exit 255
fi

if [[ ! -r "${MYSQL_CNF_PATH:-}" ]]; then
  log "reader: MySQL config unreadable: ${MYSQL_CNF_PATH:-<unset>}"
  exit 1
fi

MYSQL_ARGS=(--defaults-file="$MYSQL_CNF_PATH" --connect-timeout=3 --batch)

# Run a query and capture output; return 0 on success
run_mysql() {
  "$MYSQL_BIN" "${MYSQL_ARGS[@]}" -s -N -e "$1" 2>/dev/null
}

# Run a query intended for vertical output (\G), keeping field labels
run_mysql_vertical() {
  "$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "$1" 2>/dev/null
}

# Try SHOW REPLICA STATUS (8.0+/8.4), fallback to SHOW SLAVE STATUS (5.7/8.0)
status_output="$(run_mysql_vertical "SHOW REPLICA STATUS\\G")"
if [[ -z "$status_output" ]]; then
  status_output="$(run_mysql_vertical "SHOW SLAVE STATUS\\G" || true)"
fi

# If still empty, replication not configured or MySQL unreachable
if [[ -z "$status_output" ]]; then
  log "reader failed: no replication status or MySQL unreachable"
  exit 1
fi

# Extract fields for both nomenclatures
io_running="$(echo "$status_output" | awk -F': ' '/Replica_IO_Running:|Slave_IO_Running:/ {print $2; exit}')"
sql_running="$(echo "$status_output" | awk -F': ' '/Replica_SQL_Running:|Slave_SQL_Running:/ {print $2; exit}')"
lag_val="$(echo "$status_output" | awk -F': ' '/Seconds_Behind_Source:|Seconds_Behind_Master:/ {print $2; exit}')"

# Normalize values
io_running="${io_running:-No}"
sql_running="${sql_running:-No}"
case "$lag_val" in
  ""|NULL|null) lag=999999 ;;
  *)            lag="$lag_val" ;;
esac

# Ensure node is read-only
ro="$(run_mysql "SELECT @@global.read_only;" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')"

if [[ "$io_running" == "Yes" && "$sql_running" == "Yes" && "$lag" -lt "$MAX_LAG_SECONDS" && "$ro" == "1" ]]; then
  log "reader OK: node is healthy replica"
  exit 0
else
  log "reader failed: io=$io_running sql=$sql_running lag=${lag:-?} read_only=${ro:-<empty>} (need Yes/Yes/<${MAX_LAG_SECONDS}/1)"
  exit 1
fi

