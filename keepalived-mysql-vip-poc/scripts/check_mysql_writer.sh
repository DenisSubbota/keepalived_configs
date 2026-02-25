#!/bin/bash
# Compatibility check for MySQL 5.7 / 8.0 / 8.4
# Exits 0 only when ALL are true:
# - Node is writable: @@global.read_only=0 and @@global.super_read_only=0
# - Node is NOT a replica: no output from SHOW REPLICA STATUS/SHOW SLAVE STATUS (unless ALLOW_PRIMARY_AS_REPLICA=1)
# - At least one replica is attached: SHOW REPLICAS (8.x) or SHOW SLAVE HOSTS (5.7/8.0) non-empty
# Otherwise exits 1

set -o nounset

MYSQL_USER=${MYSQL_USER:-percona}
MYSQL_PASS=${MYSQL_PASS:-Percona1234}
MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_SOCKET=${MYSQL_SOCKET:-}
MYSQL_BIN=${MYSQL_BIN:-mysql}
ALLOW_PRIMARY_AS_REPLICA=${ALLOW_PRIMARY_AS_REPLICA:-0}

allow_primary_as_replica_norm="$(printf '%s' "$ALLOW_PRIMARY_AS_REPLICA" | tr '[:upper:]' '[:lower:]')"
case "$allow_primary_as_replica_norm" in
  1|true|yes|y) allow_primary_as_replica=1 ;;
  *)            allow_primary_as_replica=0 ;;
esac

# Build mysql CLI args safely
MYSQL_ARGS=(--user="$MYSQL_USER" --password="$MYSQL_PASS" --connect-timeout=3 --batch --skip-column-names -s -N)
if [[ -n "$MYSQL_SOCKET" ]]; then
  MYSQL_ARGS+=(--socket="$MYSQL_SOCKET")
else
  MYSQL_ARGS+=(--host="$MYSQL_HOST" --port="$MYSQL_PORT")
fi

run_mysql() {
  "$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "$1" 2>/dev/null
}

# Read-only flags: prefer @@global scope
ro="$(run_mysql "SELECT @@global.read_only;" | tail -n1 | awk '{print $1}' | tr -d '\r' || true)"
if [[ -z "$ro" || ! "$ro" =~ ^[0-9]+$ ]]; then
  exit 1
fi

# super_read_only may not exist on older 5.7, treat missing as 0
sro="$(run_mysql "SELECT @@global.super_read_only;" | tail -n1 | awk '{print $1}' | tr -d '\r' || true)"
if [[ -z "$sro" || ! "$sro" =~ ^[0-9]+$ ]]; then
  sro=0
fi

# Must be writable to be primary
if [[ ! ( "$ro" -eq 0 && "$sro" -eq 0 ) ]]; then
  exit 1
fi

if [[ "$allow_primary_as_replica" -eq 0 ]]; then
  # Ensure this node is NOT configured as a replica
  replica_status="$(run_mysql "SHOW REPLICA STATUS")"
  if [[ -z "$replica_status" ]]; then
    replica_status="$(run_mysql "SHOW SLAVE STATUS" || true)"
  fi
  if [[ -n "$replica_status" ]]; then
    # Found replica status; this node is a replica, not eligible as primary (default behavior)
    exit 1
  fi
fi

# Ensure at least one replica is connected to this primary
# Prefer SHOW REPLICAS (8.0+/8.4), fallback to SHOW SLAVE HOSTS (5.7/8.0)
replicas_out="$(run_mysql "SHOW REPLICAS" || true)"
replicas_connected=0
if [[ -n "$replicas_out" ]]; then
  replicas_connected=1
else
  slave_hosts_out="$(run_mysql "SHOW SLAVE HOSTS" || true)"
  if [[ -n "$slave_hosts_out" ]]; then
    replicas_connected=1
  fi
fi

if [[ "$replicas_connected" -eq 1 ]]; then
  exit 0
else
  exit 1
fi

