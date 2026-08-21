#!/bin/bash
# Offline tests for check_mysql.sh and notify_fifo_handler.sh.
# No MySQL and no keepalived needed: fake_mysql.sh answers the queries and a
# plain file stands in for the VRRP FIFO.
#
# Usage: bash tests/run_offline_tests.sh
# Exit 0 = all tests passed.

set -o nounset

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
CHECK="$REPO_DIR/check_mysql.sh"
NOTIFY="$REPO_DIR/notify_fifo_handler.sh"
FAKE_MYSQL="$TESTS_DIR/fake_mysql.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keepalived-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

LOG_DIR="$WORK_DIR/logs"
PROM_DIR="$WORK_DIR/prom"
MY_CNF="$WORK_DIR/my.cnf"
mkdir -p "$LOG_DIR" "$PROM_DIR"
printf '[client]\nuser=keepalived\n' > "$MY_CNF"

PASS=0
FAIL=0
LAST_OUT=""

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [[ -n "$LAST_OUT" ]] && printf '       output: %s\n' "$LAST_OUT"; }
head_() { printf '\n== %s\n' "$1"; }

# run_limited <seconds> <command...> - kills the command if it runs too long and
# returns 124, so a parsing loop that never ends shows up as a failure.
run_limited() {
  local secs="$1"; shift
  local out_file="$WORK_DIR/out.$$"
  "$@" > "$out_file" 2>&1 &
  local pid=$! waited=0 rc=0
  while kill -0 "$pid" 2>/dev/null; do
    waited=$((waited+1))
    if [[ "$waited" -gt $((secs*10)) ]]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      LAST_OUT="killed after ${secs}s"
      return 124
    fi
    sleep 0.1
  done
  wait "$pid"; rc=$?
  LAST_OUT="$(tr '\n' '|' < "$out_file")"
  rm -f "$out_file"
  return "$rc"
}

# check_case <expected-rc> <description> <env-assignments...> -- <check args...>
check_case() {
  local want="$1" desc="$2"; shift 2
  local -a envs=() args=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  args=("$@")
  local rc=0
  run_limited 10 env "${envs[@]}" bash "$CHECK" \
    --defaults-file "$MY_CNF" --mysql-bin "$FAKE_MYSQL" \
    --no-vip-file "$WORK_DIR/no_vip" --log-dir "$LOG_DIR" "${args[@]}" || rc=$?
  if [[ "$rc" -eq "$want" ]]; then ok "$desc (rc=$rc)"; else bad "$desc (want rc=$want, got $rc)"; fi
}

# notify_case <expected-rc> <description> <args...>
notify_case() {
  local want="$1" desc="$2"; shift 2
  local rc=0
  run_limited 10 bash "$NOTIFY" "$@" || rc=$?
  if [[ "$rc" -eq "$want" ]]; then ok "$desc (rc=$rc)"; else bad "$desc (want rc=$want, got $rc)"; fi
}

metric_is() {
  local file="$1" want="$2" desc="$3" got
  got="$(awk -F'} ' '/^percona_keepalived_mysql\{/ {print $2; exit}' "$file" 2>/dev/null)"
  LAST_OUT="file=$file value=${got:-<none>}"
  if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc (want $want, got ${got:-<none>})"; fi
}

head_ "check_mysql.sh - writer checks"
check_case 0 "primary: writable, no replication" \
  FM_READ_ONLY=0 FM_REPL=none -- --primary
check_case 1 "primary: read_only=1" \
  FM_READ_ONLY=1 FM_REPL=none -- --primary
check_case 1 "primary: MySQL unreachable" \
  FM_DOWN=1 -- --primary
check_case 1 "primary: replication configured, no override flag" \
  FM_READ_ONLY=0 FM_REPL=yes -- --primary
check_case 1 "primary: replicating from the peer" \
  FM_READ_ONLY=0 FM_REPL=yes FM_SOURCE_HOST=10.20.30.11 -- \
  --primary --allow-replica-except-from 10.20.30.11
check_case 0 "primary: replicating from a third host" \
  FM_READ_ONLY=0 FM_REPL=yes FM_SOURCE_HOST=10.20.30.99 -- \
  --primary --allow-replica-except-from 10.20.30.11
check_case 1 "primary: replicating from the peer, MySQL 5.7 field names" \
  FM_FLAVOR=57 FM_READ_ONLY=0 FM_REPL=yes FM_SOURCE_HOST=10.20.30.11 -- \
  --primary --allow-replica-except-from 10.20.30.11
check_case 1 "primary: replicating from the peer, MySQL 8.4 field names" \
  FM_FLAVOR=84 FM_READ_ONLY=0 FM_REPL=yes FM_SOURCE_HOST=10.20.30.11 -- \
  --primary --allow-replica-except-from 10.20.30.11
check_case 1 "primary: replication configured but Source_Host unreadable (fail closed)" \
  FM_READ_ONLY=0 FM_REPL=yes FM_NO_SOURCE=1 -- \
  --primary --allow-replica-except-from 10.20.30.11

head_ "check_mysql.sh - reader checks"
check_case 0 "replica: healthy, MySQL 8.0" \
  FM_READ_ONLY=1 FM_REPL=yes -- --replica
check_case 0 "replica: healthy, MySQL 5.7" \
  FM_FLAVOR=57 FM_READ_ONLY=1 FM_REPL=yes -- --replica
check_case 0 "replica: healthy, MySQL 8.4" \
  FM_FLAVOR=84 FM_READ_ONLY=1 FM_REPL=yes -- --replica
check_case 1 "replica: read_only=0" \
  FM_READ_ONLY=0 FM_REPL=yes -- --replica
check_case 1 "replica: IO thread stopped" \
  FM_READ_ONLY=1 FM_REPL=yes FM_IO=No -- --replica
check_case 1 "replica: SQL thread stopped" \
  FM_READ_ONLY=1 FM_REPL=yes FM_SQL=No -- --replica
check_case 1 "replica: no replication configured" \
  FM_READ_ONLY=1 FM_REPL=none -- --replica
check_case 1 "replica: lag NULL" \
  FM_READ_ONLY=1 FM_REPL=yes FM_LAG=NULL -- --replica
check_case 1 "replica: lag not a number does not crash the script" \
  FM_READ_ONLY=1 FM_REPL=yes FM_LAG=broken -- --replica
check_case 1 "replica: lag 400 over --max-lag 10" \
  FM_READ_ONLY=1 FM_REPL=yes FM_LAG=400 -- --replica --max-lag 10
check_case 0 "replica: lag 5 under --max-lag 10" \
  FM_READ_ONLY=1 FM_REPL=yes FM_LAG=5 -- --replica --max-lag 10

head_ "check_mysql.sh - writer-or-reader"
check_case 0 "writer-or-reader on the primary" \
  FM_READ_ONLY=0 FM_REPL=none -- --writer-or-reader --allow-replica-except-from 10.20.30.11
check_case 0 "writer-or-reader on a healthy replica" \
  FM_READ_ONLY=1 FM_REPL=yes -- --writer-or-reader --allow-replica-except-from 10.20.30.11
check_case 1 "writer-or-reader when neither role is healthy" \
  FM_READ_ONLY=1 FM_REPL=none -- --writer-or-reader --allow-replica-except-from 10.20.30.11
check_case 1 "writer-or-reader: writable but replicating from the peer" \
  FM_READ_ONLY=0 FM_REPL=yes FM_SOURCE_HOST=10.20.30.11 -- \
  --writer-or-reader --allow-replica-except-from 10.20.30.11

head_ "check_mysql.sh - kill switch and option handling"
touch "$WORK_DIR/no_vip"
check_case 1 "no_vip file drains the VIPs" \
  FM_READ_ONLY=0 FM_REPL=none -- --primary
rm -f "$WORK_DIR/no_vip"
check_case 2 "--max-lag with a non-number is an error" \
  FM_READ_ONLY=1 FM_REPL=yes -- --replica --max-lag abc
check_case 2 "--max-lag with no value is an error" \
  FM_READ_ONLY=1 FM_REPL=yes -- --replica --max-lag
check_case 2 "two modes at once is an error" \
  FM_READ_ONLY=0 -- --primary --replica
check_case 2 "no mode is an error" \
  FM_READ_ONLY=0 -- --log-max-size 1024
check_case 2 "unknown option is an error" \
  FM_READ_ONLY=0 -- --replica --bogus
check_case 0 "--help exits 0" \
  FM_READ_ONLY=0 -- --help

LAST_OUT=""
if bash "$CHECK" --help | grep -q 'set -o nounset'; then
  bad "--help must not print script code"
else
  ok "--help prints only the help text"
fi

if [[ -s "$LOG_DIR/keepalived_check_mysql.log" ]]; then
  ok "decisions are written to the log file"
else
  bad "log file is empty"
fi

head_ "notify_fifo_handler.sh - option handling"
EVENTS="$WORK_DIR/events"
printf 'INSTANCE "VI_MYSQL_WRITER" MASTER 10\n' > "$EVENTS"
notify_case 2 "missing --cluster is an error" \
  --writer-vip 10.0.0.1 --reader-vip 10.0.0.2 --prom-output-dir "$PROM_DIR" "$EVENTS"
notify_case 2 "a flag with no value does not hang" \
  --writer-vip 10.0.0.1 --reader-vip 10.0.0.2 --prom-output-dir "$PROM_DIR" "$EVENTS" --cluster
notify_case 2 "a misspelled flag is rejected" \
  --cluster c1 --writer-vip 10.0.0.1 --reader-vip 10.0.0.2 --prom-outputdir "$PROM_DIR" "$EVENTS"
notify_case 2 "two positional arguments are rejected" \
  --cluster c1 --writer-vip 10.0.0.1 --reader-vip 10.0.0.2 --prom-output-dir "$PROM_DIR" "$EVENTS" "$EVENTS"
notify_case 2 "--priority-threshold with a non-number is an error" \
  --cluster c1 --writer-vip 10.0.0.1 --reader-vip 10.0.0.2 --priority-threshold high \
  --prom-output-dir "$PROM_DIR" "$EVENTS"
notify_case 0 "--help exits 0" --help

head_ "notify_fifo_handler.sh - VRRP state mapping"
run_notify() {
  rm -f "$PROM_DIR"/*.prom 2>/dev/null
  printf '%s\n' "$1" > "$EVENTS"
  run_limited 10 bash "$NOTIFY" --cluster c1 --writer-vip 10.0.0.1 --reader-vip 10.0.0.2 \
    --priority-threshold 10 --prom-output-dir "$PROM_DIR" "$EVENTS"
}

run_notify 'INSTANCE "VI_MYSQL_WRITER" MASTER 10'
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.1.prom" 0 "MASTER at the threshold is healthy"

run_notify 'INSTANCE "VI_MYSQL_WRITER" BACKUP 10'
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.1.prom" 1 "BACKUP is unhealthy"

run_notify 'INSTANCE "VI_MYSQL_WRITER" FAULT 10'
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.1.prom" 1 "FAULT is unhealthy"

run_notify 'INSTANCE "VI_MYSQL_WRITER" MASTER_PRIORITY 5'
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.1.prom" 1 "MASTER_PRIORITY below the threshold is unhealthy (sticky mode)"

run_notify 'INSTANCE "VI_MYSQL_WRITER" MASTER_PRIORITY 15'
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.1.prom" 0 "MASTER_PRIORITY above the threshold is healthy"

run_notify 'INSTANCE "VI_MYSQL_READER" MASTER_RX_LOWER_PRI 20'
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.2.prom" 0 "MASTER_RX_LOWER_PRI still counts as holding the VIP"

run_notify 'INSTANCE "VI_MYSQL_READER" STOP 0'
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.2.prom" 1 "STOP is unhealthy"

LAST_OUT=""
rm -f "$PROM_DIR"/*.prom 2>/dev/null
{
  printf 'GROUP "GRP1" MASTER 10\n'
  printf 'INSTANCE "VI_OTHER" MASTER 10\n'
  printf 'INSTANCE "VI_MYSQL_WRITER" MASTER abc\n'
  printf 'INSTANCE "VI_MYSQL_READER" MASTER 20'
} > "$EVENTS"
if run_limited 10 bash "$NOTIFY" --cluster c1 --writer-vip 10.0.0.1 --reader-vip 10.0.0.2 \
     --prom-output-dir "$PROM_DIR" "$EVENTS"; then
  ok "noise lines and a bad priority do not kill the reader loop"
else
  bad "handler died on a bad line"
fi
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.1.prom" 0 "a bad priority falls back to the state (MASTER)"
metric_is "$PROM_DIR/keepalived_mysql_10.0.0.2.prom" 0 "the last line without a newline is still handled"

LAST_OUT=""
if ls "$PROM_DIR"/*.tmp >/dev/null 2>&1; then
  bad "temp files left behind in the textfile-collector directory"
else
  ok "no temp files left in the textfile-collector directory"
fi

printf '\n%s\n' "-----------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
