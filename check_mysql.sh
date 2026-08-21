#!/bin/bash
# Unified MySQL health check for Keepalived (MySQL 5.7 / 8.0 / 8.4).
# Run "check_mysql.sh --help" for the full option list.
#
# Exit: 0 = check passed, 1 = check failed, 2 = usage or config error.

set -o nounset

# --- Defaults ---
MYSQL_CNF_PATH="/home/percona/.my.cnf"
MYSQL_BIN="mysql"
MAX_LAG_SECONDS="300"
CONNECT_TIMEOUT="3"
NO_VIP_FILE="/etc/keepalived/no_vip"
LOG_DIR="/var/log/percona"
LOG_MAX_SIZE="52428800"
LOG_ROTATE_KEEP="7"
ALLOW_REPLICA_EXCEPT_FROM=""

MODE=""
SELF="${0##*/}"
LOG_FILE="${LOG_DIR}/keepalived_check_mysql.log"

# --- Logging (defined before argument parsing so usage errors are logged too) ---
rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size i
  size=$(wc -c < "$LOG_FILE" 2>/dev/null) || return 0
  size="${size//[[:space:]]/}"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  [[ "$size" -ge "$LOG_MAX_SIZE" ]] || return 0
  rm -f "${LOG_FILE}.${LOG_ROTATE_KEEP}" 2>/dev/null || true
  for (( i=LOG_ROTATE_KEEP-1; i>=1; i-- )); do
    [[ -f "${LOG_FILE}.$i" ]] && mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))" 2>/dev/null || true
  done
  mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
}

log() {
  [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  [[ -w "$LOG_DIR" ]] || return 0
  rotate_log
  if [[ ! -e "$LOG_FILE" ]]; then
    : > "$LOG_FILE" 2>/dev/null || return 0
    chmod 644 "$LOG_FILE" 2>/dev/null || true
  fi
  printf '%s [%s] %s\n' "$(date -Iseconds)" "${MODE:-usage}" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

usage() {
  cat <<'EOF'
Unified MySQL health check for Keepalived (MySQL 5.7 / 8.0 / 8.4)

Modes (exactly one required):
  --primary           Node must be a writable primary (read_only=0, not replicating from the peer)
  --replica           Node must be a healthy replica (read_only=1, IO/SQL running, lag under --max-lag)
  --writer-or-reader  Node must be either a healthy primary OR a healthy replica (reader VIP fallback)

Options:
  --defaults-file PATH              MySQL client option file (same as mysql --defaults-file)
                                    [default: /home/percona/.my.cnf]
  --mysql-bin PATH                  mysql binary [default: mysql]
  --connect-timeout N               MySQL client connect timeout in seconds [default: 3]
  --max-lag N                       Max replication lag in seconds; used by --replica and
                                    --writer-or-reader [default: 300]
  --no-vip-file PATH                If this file exists, every check fails so the VIPs leave the node
                                    [default: /etc/keepalived/no_vip]
  --log-dir DIR                     Log directory [default: /var/log/percona]
  --log-max-size N                  Rotate when the log exceeds N bytes [default: 52428800 = 50 MiB]
  --log-rotate-keep N               Keep N rotated log files [default: 7]
  --allow-replica-except-from IP    Let the primary check pass even when replication is configured,
                                    unless Source_Host/Master_Host equals IP. Used by --primary and
                                    --writer-or-reader. Set IP to the Keepalived peer address so a
                                    node replicating from its peer is never taken for the primary.
  -h, --help                        Show this help and exit

Exit: 0 = check passed, 1 = check failed, 2 = usage or config error.
EOF
}

# --- Argument helpers ---
die_usage() {
  echo "${SELF}: $*" >&2
  echo "${SELF}: run '${SELF} --help' for the option list" >&2
  log "usage error: $*"
  exit 2
}

need_value() {
  # need_value <flag> <args-left-including-the-flag>
  [[ "$2" -ge 2 ]] || die_usage "option $1 needs a value"
}

need_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] || die_usage "option $1 needs a whole number, got: '$2'"
}

need_path() {
  [[ -n "$2" ]] || die_usage "option $1 needs a non-empty value"
}

set_mode() {
  [[ -z "$MODE" ]] || die_usage "only one mode is allowed (--${MODE//_/-} was already given)"
  MODE="$1"
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary)          set_mode "primary";          shift ;;
    --replica)          set_mode "replica";          shift ;;
    --writer-or-reader) set_mode "writer_or_reader"; shift ;;
    --max-lag)
      need_value "$1" $#; need_uint "$1" "$2"
      MAX_LAG_SECONDS="$2"; shift 2 ;;
    --connect-timeout)
      need_value "$1" $#; need_uint "$1" "$2"
      CONNECT_TIMEOUT="$2"; shift 2 ;;
    --defaults-file)
      need_value "$1" $#; need_path "$1" "$2"
      MYSQL_CNF_PATH="$2"; shift 2 ;;
    --mysql-bin)
      need_value "$1" $#; need_path "$1" "$2"
      MYSQL_BIN="$2"; shift 2 ;;
    --no-vip-file)
      need_value "$1" $#; need_path "$1" "$2"
      NO_VIP_FILE="$2"; shift 2 ;;
    --log-dir)
      need_value "$1" $#; need_path "$1" "$2"
      LOG_DIR="$2"; shift 2 ;;
    --log-max-size)
      need_value "$1" $#; need_uint "$1" "$2"
      LOG_MAX_SIZE="$2"; shift 2 ;;
    --log-rotate-keep)
      need_value "$1" $#; need_uint "$1" "$2"
      [[ "$2" -ge 1 ]] || die_usage "option $1 needs a number of 1 or more"
      LOG_ROTATE_KEEP="$2"; shift 2 ;;
    --allow-replica-except-from)
      need_value "$1" $#; need_path "$1" "$2"
      ALLOW_REPLICA_EXCEPT_FROM="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die_usage "unknown option: $1" ;;
  esac
done

[[ -n "$MODE" ]] || die_usage "no mode given, use --primary, --replica or --writer-or-reader"

# --log-dir may have changed the log path
LOG_FILE="${LOG_DIR}/keepalived_check_mysql.log"

# --- Shared: no_vip and config ---
if [[ -e "$NO_VIP_FILE" ]]; then
  log "VIP disabled: $NO_VIP_FILE exists"
  exit 1
fi

if [[ ! -r "$MYSQL_CNF_PATH" ]]; then
  log "MySQL config unreadable: $MYSQL_CNF_PATH"
  exit 1
fi

# --- MySQL access ---
# Keep the stderr of the last mysql call so a failure can be logged with a
# reason. One fixed file per mode, overwritten on every run: keepalived kills a
# slow script with SIGKILL, and a mktemp file would then pile up in /tmp.
MYSQL_ERR_FILE=""
if mkdir -p "$LOG_DIR" 2>/dev/null && [[ -w "$LOG_DIR" ]]; then
  MYSQL_ERR_FILE="${LOG_DIR}/.check_mysql_last_error.${MODE}"
fi

mysql_err() {
  [[ -n "$MYSQL_ERR_FILE" && -s "$MYSQL_ERR_FILE" ]] || return 0
  tr '\n' ' ' < "$MYSQL_ERR_FILE"
}

MYSQL_ARGS=(--defaults-file="$MYSQL_CNF_PATH" --connect-timeout="$CONNECT_TIMEOUT" --batch --skip-column-names -s -N)
# Vertical output (\G) must keep the "Field: Value" lines for parsing, so no --skip-column-names here.
MYSQL_ARGS_VERTICAL=(--defaults-file="$MYSQL_CNF_PATH" --connect-timeout="$CONNECT_TIMEOUT" --batch)

run_mysql() {
  [[ -n "$MYSQL_ERR_FILE" ]] && : > "$MYSQL_ERR_FILE"
  "$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "$1" 2>"${MYSQL_ERR_FILE:-/dev/null}"
}

run_mysql_vertical() {
  [[ -n "$MYSQL_ERR_FILE" ]] && : > "$MYSQL_ERR_FILE"
  "$MYSQL_BIN" "${MYSQL_ARGS_VERTICAL[@]}" -e "$1" 2>"${MYSQL_ERR_FILE:-/dev/null}"
}

# --- Cached queries ---
# Both checks need read_only and the replica status, and --writer-or-reader runs
# both checks. Ask MySQL once per run so a slow server cannot multiply the
# connect timeout past the keepalived script timeout.
READ_ONLY_VALUE=""
READ_ONLY_ERR=""
READ_ONLY_CACHED=0
fetch_read_only() {
  [[ "$READ_ONLY_CACHED" -eq 0 ]] || return 0
  READ_ONLY_CACHED=1
  local raw
  raw="$(run_mysql "SELECT @@global.read_only;")" || READ_ONLY_ERR="$(mysql_err)"
  READ_ONLY_VALUE="$(printf '%s' "$raw" | tr -d '\r\n' | awk '{print $1}')"
}

REPLICA_STATUS=""
REPLICA_STATUS_CACHED=0
fetch_replica_status() {
  # Vertical "SHOW REPLICA STATUS" output, empty when replication is not
  # configured or MySQL is unreachable. 8.4 dropped the SLAVE spelling and 5.7
  # does not know the REPLICA one, so try both.
  [[ "$REPLICA_STATUS_CACHED" -eq 0 ]] || return 0
  REPLICA_STATUS_CACHED=1
  REPLICA_STATUS="$(run_mysql_vertical "SHOW REPLICA STATUS\\G")"
  [[ -z "$REPLICA_STATUS" ]] && REPLICA_STATUS="$(run_mysql_vertical "SHOW SLAVE STATUS\\G")"
  return 0
}

repl_field() {
  # repl_field <field-name-pattern> - value of the first matching field of the
  # first channel, empty when the field is absent.
  awk -F': ' -v pat="$1" '$0 ~ pat { print $2; exit }'
}

repl_has_field() {
  awk -v pat="$1" '$0 ~ pat { found=1; exit } END { exit found ? 0 : 1 }'
}

SOURCE_HOST_PATTERN='^[[:space:]]*(Source_Host|Master_Host):'

# --- Check: primary (writer) ---
# Success: read_only=0.
# Without --allow-replica-except-from: no replication may be configured.
# With    --allow-replica-except-from IP: replication is allowed unless Source_Host is IP.
check_primary() {
  local read_only source_host
  fetch_read_only
  read_only="$READ_ONLY_VALUE"
  if [[ "$read_only" != "0" ]]; then
    if [[ -z "$read_only" ]]; then
      log "primary failed: cannot read @@global.read_only${READ_ONLY_ERR:+ (mysql: ${READ_ONLY_ERR})}"
    else
      log "primary failed: read_only=${read_only} (must be 0)"
    fi
    return 1
  fi

  fetch_replica_status
  if [[ -z "$REPLICA_STATUS" ]]; then
    log "primary OK: node is a healthy primary (no replication configured)"
    return 0
  fi

  if [[ -z "$ALLOW_REPLICA_EXCEPT_FROM" ]]; then
    log "primary failed: node is configured as a replica; use --allow-replica-except-from to override"
    return 1
  fi

  if ! printf '%s\n' "$REPLICA_STATUS" | repl_has_field "$SOURCE_HOST_PATTERN"; then
    # Replication is configured but the source cannot be read, so we cannot show
    # the node is not replicating from its peer. Fail closed.
    log "primary failed: replication is configured but Source_Host/Master_Host could not be read"
    return 1
  fi

  source_host="$(printf '%s\n' "$REPLICA_STATUS" | repl_field "$SOURCE_HOST_PATTERN")"
  source_host="${source_host//[[:space:]]/}"
  if [[ "$source_host" == "$ALLOW_REPLICA_EXCEPT_FROM" ]]; then
    log "primary failed: Source_Host=${source_host} matches peer ${ALLOW_REPLICA_EXCEPT_FROM}, node is not the primary"
    return 1
  fi

  log "primary OK: node is writable, replicating from ${source_host:-<empty>} (not peer ${ALLOW_REPLICA_EXCEPT_FROM})"
  return 0
}

# --- Check: replica (reader) ---
# Success: read_only=1, IO and SQL threads running, lag below --max-lag.
check_replica() {
  local io_running sql_running lag_raw lag read_only
  local -a failure_reasons=()

  fetch_read_only
  read_only="$READ_ONLY_VALUE"
  fetch_replica_status

  if [[ -z "$REPLICA_STATUS" ]]; then
    log "replica failed: no replication status, or MySQL unreachable${READ_ONLY_ERR:+ (mysql: ${READ_ONLY_ERR})}"
    return 1
  fi

  io_running="$(printf '%s\n' "$REPLICA_STATUS"  | repl_field '^[[:space:]]*(Replica_IO_Running|Slave_IO_Running):')"
  sql_running="$(printf '%s\n' "$REPLICA_STATUS" | repl_field '^[[:space:]]*(Replica_SQL_Running|Slave_SQL_Running):')"
  lag_raw="$(printf '%s\n' "$REPLICA_STATUS"     | repl_field '^[[:space:]]*(Seconds_Behind_Source|Seconds_Behind_Master):')"
  io_running="${io_running//[[:space:]]/}"
  sql_running="${sql_running//[[:space:]]/}"
  lag_raw="${lag_raw//[[:space:]]/}"

  # -1 means "lag unknown": NULL (replication stopped) or a value that is not a
  # number. Never compare a non-number with -lt, that aborts under nounset.
  case "$lag_raw" in
    ""|NULL|null) lag=-1 ;;
    *[!0-9]*)     lag=-1 ;;
    *)            lag="$lag_raw" ;;
  esac

  if [[ "$io_running" == "Yes" && "$sql_running" == "Yes" && "$read_only" == "1" \
        && "$lag" -ge 0 && "$lag" -lt "$MAX_LAG_SECONDS" ]]; then
    log "replica OK: node is a healthy replica (lag=${lag}s)"
    return 0
  fi

  [[ "$io_running" != "Yes" ]]  && failure_reasons+=("IO thread not running (is: ${io_running:-<empty>})")
  [[ "$sql_running" != "Yes" ]] && failure_reasons+=("SQL thread not running (is: ${sql_running:-<empty>})")
  [[ "$read_only" != "1" ]]     && failure_reasons+=("read_only is ${read_only:-<empty>}, must be 1")
  if [[ "$lag" -lt 0 ]]; then
    failure_reasons+=("lag unknown (Seconds_Behind_Source=${lag_raw:-<empty>})")
  elif [[ "$lag" -ge "$MAX_LAG_SECONDS" ]]; then
    failure_reasons+=("lag ${lag}s >= ${MAX_LAG_SECONDS}s")
  fi
  log "replica failed: $(IFS='; '; echo "${failure_reasons[*]}")"
  return 1
}

# --- Main: run the selected mode ---
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
    if check_primary || check_replica; then
      exit 0
    fi
    log "writer_or_reader failed: node is neither a healthy primary nor a healthy replica"
    exit 1
    ;;
esac
