#!/bin/bash
# Stand-in for the mysql client, used by run_offline_tests.sh.
# It answers the two queries check_mysql.sh sends, driven by env variables:
#
#   FM_FLAVOR       57 | 80 | 84   which SHOW syntax is accepted and which field
#                                  names are printed (default 80 = both)
#   FM_DOWN         1              behave like an unreachable server
#   FM_READ_ONLY    0 | 1          value of @@global.read_only (default 0)
#   FM_REPL         none | yes     is replication configured (default none)
#   FM_SOURCE_HOST  IP             Source_Host/Master_Host value (default 10.20.30.11)
#   FM_IO           Yes | No       IO thread state (default Yes)
#   FM_SQL          Yes | No       SQL thread state (default Yes)
#   FM_LAG          N | NULL       Seconds_Behind_Source (default 0)
#   FM_NO_SOURCE    1              print the replica row without a Source_Host field

set -o nounset

QUERY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e) QUERY="${2:-}"; shift 2 ;;
    *)  shift ;;
  esac
done

FLAVOR="${FM_FLAVOR:-80}"

if [[ "${FM_DOWN:-0}" == "1" ]]; then
  echo "ERROR 2002 (HY000): Can't connect to local MySQL server through socket '/tmp/mysql.sock' (2)" >&2
  exit 1
fi

case "$QUERY" in
  *"@@global.read_only"*)
    echo "${FM_READ_ONLY:-0}"
    exit 0
    ;;
esac

# 5.7 knows only SLAVE, 8.4 knows only REPLICA, 8.0 knows both.
if [[ "$FLAVOR" == "57" && "$QUERY" == *REPLICA* ]]; then
  echo "ERROR 1064 (42000): You have an error in your SQL syntax near 'REPLICA STATUS'" >&2
  exit 1
fi
if [[ "$FLAVOR" == "84" && "$QUERY" == *SLAVE* ]]; then
  echo "ERROR 1064 (42000): You have an error in your SQL syntax near 'SLAVE STATUS'" >&2
  exit 1
fi

[[ "${FM_REPL:-none}" == "yes" ]] || exit 0

SRC="${FM_SOURCE_HOST:-10.20.30.11}"
IO="${FM_IO:-Yes}"
SQL="${FM_SQL:-Yes}"
LAG="${FM_LAG:-0}"

if [[ "$FLAVOR" == "57" ]]; then
  SRC_FIELD="Master_Host"
  IO_FIELD="Slave_IO_Running"
  SQL_FIELD="Slave_SQL_Running"
  LAG_FIELD="Seconds_Behind_Master"
  STATE_FIELD="Slave_IO_State"
  STATE_VALUE="Waiting for master to send event"
else
  SRC_FIELD="Source_Host"
  IO_FIELD="Replica_IO_Running"
  SQL_FIELD="Replica_SQL_Running"
  LAG_FIELD="Seconds_Behind_Source"
  STATE_FIELD="Replica_IO_State"
  STATE_VALUE="Waiting for source to send event"
fi

if [[ "$QUERY" == *'\G' ]]; then
  echo "*************************** 1. row ***************************"
  printf '%22s: %s\n' "$STATE_FIELD" "$STATE_VALUE"
  [[ "${FM_NO_SOURCE:-0}" == "1" ]] || printf '%22s: %s\n' "$SRC_FIELD" "$SRC"
  printf '%22s: %s\n' "${SRC_FIELD%_Host}_User" "repl"
  printf '%22s: %s\n' "$IO_FIELD" "$IO"
  printf '%22s: %s\n' "$SQL_FIELD" "$SQL"
  printf '%22s: %s\n' "$LAG_FIELD" "$LAG"
  printf '%22s: %s\n' "Last_IO_Error" ""
else
  printf '%s\t%s\t%s\t%s\t%s\n' "$STATE_VALUE" "$SRC" "$IO" "$SQL" "$LAG"
fi
exit 0
