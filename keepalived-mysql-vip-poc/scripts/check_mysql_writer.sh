#!/bin/bash
# Compatibilite with MySQL 5.7 / 8.0 / 8.4
# Node considered as healty Writer if next conditions are true:
# - Node is writable: @@global.read_only=0
# - Node is NOT a replica: no output from SHOW REPLICA STATUS/SHOW SLAVE STATUS (unless ALLOW_PRIMARY_AS_REPLICA=1)
# Otherwise node is considered as unhealthy Writer

set -o nounset
# Client option file path only (same format for MySQL/MariaDB/PXC/Percona). Must contain [client] with user, password, host, port/socket.
MYSQL_CNF_PATH=${MYSQL_CNF_PATH:-/home/percona/.my.cnf}
MYSQL_BIN=${MYSQL_BIN:-mysql}
ALLOW_PRIMARY_AS_REPLICA=${ALLOW_PRIMARY_AS_REPLICA:-0}
NO_VIP_FILE=${NO_VIP_FILE:-/etc/keepalived/no_vip}
LOG_DIR=${LOG_DIR:-/var/log/percona}
LOG_FILE="${LOG_DIR}/keepalived_check_mysql_writer.log"
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
  log "no_vip file present, not claiming writer VIP"
  exit 255
fi

if [[ ! -r "${MYSQL_CNF_PATH:-}" ]]; then
  log "writer: MySQL config unreadable: ${MYSQL_CNF_PATH:-<unset>}"
  exit 1
fi

allow_primary_as_replica=0
[[ "${ALLOW_PRIMARY_AS_REPLICA:-}" == "1" ]] && allow_primary_as_replica=1

MYSQL_ARGS=(--defaults-file="$MYSQL_CNF_PATH" --connect-timeout=3 --batch --skip-column-names -s -N)

run_mysql() {
  "$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "$1" 2>/dev/null
}

# Must be writable: read_only must be 0 (accept only 0, 1, or empty e.g. on MySQL errors)
ro="$(run_mysql "SELECT @@global.read_only;" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')"
if [[ "$ro" != "0" ]]; then
  log "writer failed: read_only=${ro:-<empty>} (must be 0 for primary)"
  exit 1
fi

if [[ "$allow_primary_as_replica" -eq 0 ]]; then
  # Ensure this node is NOT configured as a replica
  replica_status="$(run_mysql "SHOW REPLICA STATUS")"
  if [[ -z "$replica_status" ]]; then
    replica_status="$(run_mysql "SHOW SLAVE STATUS" || true)"
  fi
  if [[ -n "$replica_status" ]]; then
    log "writer failed: node is replica, cannot be primary"
    exit 1
  fi
fi
log "writer OK: node is healthy primary"
exit 0

