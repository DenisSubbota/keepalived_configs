#!/bin/bash
# Compatibility check for MySQL 5.7 / 8.0 / 8.4
# Exits 0 when replication is healthy for reader VIP, otherwise 1

set -o nounset

MYSQL_USER=${MYSQL_USER:-percona}
MYSQL_PASS=${MYSQL_PASS:-Percona1234}
MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_SOCKET=${MYSQL_SOCKET:-}
MAX_LAG_SECONDS=${MAX_LAG_SECONDS:-300}
MYSQL_BIN=${MYSQL_BIN:-mysql}

# Build mysql CLI args safely
MYSQL_ARGS=(--user="$MYSQL_USER" --password="$MYSQL_PASS" --connect-timeout=3 --batch )
if [[ -n "$MYSQL_SOCKET" ]]; then
  MYSQL_ARGS+=(--socket="$MYSQL_SOCKET")
else
  MYSQL_ARGS+=(--host="$MYSQL_HOST" --port="$MYSQL_PORT")
fi

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

# Ensure node is read-only (reader should not be writable)
ro_val="$(run_mysql "SELECT @@global.read_only;" | tail -n1 | tr -d '\r' | awk '{print $1}' || true)"
if [[ -z "$ro_val" || ! "$ro_val" =~ ^[0-9]+$ ]]; then
  exit 1
fi

if [[ "$io_running" == "Yes" && "$sql_running" == "Yes" && "$lag" -lt "$MAX_LAG_SECONDS" && "$ro_val" -eq 1 ]]; then
  exit 0
else
  exit 1
fi

