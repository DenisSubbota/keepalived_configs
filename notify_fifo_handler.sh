#!/bin/bash
# Keepalived FIFO notify handler: writes Prometheus textfile metrics for the MySQL VIPs.
#
# Keepalived starts this script once (vrrp_notify_fifo_script) and passes the FIFO
# path as the last argument. Every VRRP state or priority change arrives as a line
#   INSTANCE "VI_MYSQL_WRITER" MASTER 10
# and is turned into one .prom file per VIP.
#
# Run "notify_fifo_handler.sh --help" for the option list.

set -o nounset

SELF="${0##*/}"

CLUSTER_NAME=""
WRITER_VIP=""
READER_VIP=""
WRITER_INSTANCE="VI_MYSQL_WRITER"
READER_INSTANCE="VI_MYSQL_READER"
PRIORITY_THRESHOLD=10
PROM_OUTPUT_DIR="/home/percona/pmm/collectors/textfile-collector/high-resolution"
FIFO_PATH=""

usage() {
  cat <<'EOF'
Keepalived FIFO notify handler: writes Prometheus textfile metrics for the MySQL VIPs

Usage:
  notify_fifo_handler.sh --cluster NAME --writer-vip IP --reader-vip IP [options] <FIFO_PATH>

Keepalived appends FIFO_PATH itself, so leave it out of vrrp_notify_fifo_script.

Options:
  --cluster NAME            Cluster label put on every metric (required)
  --writer-vip IP           Writer VIP: metric label and file name (required)
  --reader-vip IP           Reader VIP: metric label and file name (required)
  --writer-instance NAME    vrrp_instance name of the writer VIP [default: VI_MYSQL_WRITER]
  --reader-instance NAME    vrrp_instance name of the reader VIP [default: VI_MYSQL_READER]
  --priority-threshold N    A MASTER state with an effective priority below N is reported as
                            unhealthy (1). Set it to the base "priority" of the vrrp_instance
                            blocks so sticky mode (negative track_script weights) is reported
                            as unhealthy [default: 10]
  --prom-output-dir DIR     Where the .prom files go
                            [default: /home/percona/pmm/collectors/textfile-collector/high-resolution]
  -h, --help                Show this help and exit

Metrics per VIP, in <prom-output-dir>/keepalived_mysql_<vip>.prom:
  percona_keepalived_mysql                  0 = node holds the VIP, 1 = it does not
  percona_keepalived_mysql_last_report_ts   unix time of the last VRRP event for that VIP
EOF
}

die() {
  echo "${SELF}: $*" >&2
  echo "${SELF}: run '${SELF} --help' for the option list" >&2
  exit 2
}

need_value() {
  # need_value <flag> <args-left-including-the-flag>
  [[ "$2" -ge 2 ]] || die "option $1 needs a value"
}

need_nonempty() {
  [[ -n "$2" ]] || die "option $1 needs a non-empty value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)         need_value "$1" $#; need_nonempty "$1" "$2"; CLUSTER_NAME="$2";     shift 2 ;;
    --writer-vip)      need_value "$1" $#; need_nonempty "$1" "$2"; WRITER_VIP="$2";       shift 2 ;;
    --reader-vip)      need_value "$1" $#; need_nonempty "$1" "$2"; READER_VIP="$2";       shift 2 ;;
    --writer-instance) need_value "$1" $#; need_nonempty "$1" "$2"; WRITER_INSTANCE="$2";  shift 2 ;;
    --reader-instance) need_value "$1" $#; need_nonempty "$1" "$2"; READER_INSTANCE="$2";  shift 2 ;;
    --prom-output-dir) need_value "$1" $#; need_nonempty "$1" "$2"; PROM_OUTPUT_DIR="$2";  shift 2 ;;
    --priority-threshold)
      need_value "$1" $#
      [[ "$2" =~ ^[0-9]+$ ]] || die "option $1 needs a whole number, got: '$2'"
      PRIORITY_THRESHOLD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)
      [[ -z "$FIFO_PATH" ]] || die "only one FIFO path is allowed, got '$FIFO_PATH' and '$1'"
      FIFO_PATH="$1"; shift ;;
  esac
done

[[ -n "$CLUSTER_NAME" ]] || die "missing --cluster"
[[ -n "$WRITER_VIP" ]]   || die "missing --writer-vip"
[[ -n "$READER_VIP" ]]   || die "missing --reader-vip"
[[ -n "$FIFO_PATH" ]]    || die "no FIFO path (keepalived passes it as the last argument)"
[[ -r "$FIFO_PATH" ]]    || die "FIFO not readable: $FIFO_PATH"

mkdir -p "$PROM_OUTPUT_DIR" 2>/dev/null || true
[[ -d "$PROM_OUTPUT_DIR" && -w "$PROM_OUTPUT_DIR" ]] || {
  echo "${SELF}: textfile-collector directory is missing or not writable, no metrics will be written: $PROM_OUTPUT_DIR" >&2
  exit 0
}

echo "${SELF}: reading $FIFO_PATH (cluster=$CLUSTER_NAME writer=$WRITER_VIP reader=$READER_VIP threshold=$PRIORITY_THRESHOLD)" >&2

write_prom() {
  local vip="$1" role="$2" value="$3"
  local labels="cluster=\"$CLUSTER_NAME\",vip=\"$vip\",role=\"$role\""
  local ts output_file tmp_file
  ts=$(date +%s)
  output_file="${PROM_OUTPUT_DIR}/keepalived_mysql_${vip}.prom"
  # Write to a temp name that does not end in .prom, then rename, so the
  # textfile collector never reads a half-written file.
  tmp_file="${output_file}.$$.tmp"
  {
    echo "# HELP percona_keepalived_mysql Keepalived MySQL VIP status (0=ok, 1=fail)"
    echo "# TYPE percona_keepalived_mysql untyped"
    echo "# HELP percona_keepalived_mysql_last_report_ts Keepalived MySQL VIP last report timestamp"
    echo "# TYPE percona_keepalived_mysql_last_report_ts untyped"
    printf 'percona_keepalived_mysql{%s} %s\n' "$labels" "$value"
    printf 'percona_keepalived_mysql_last_report_ts{%s} %s\n' "$labels" "$ts"
  } > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file" 2>/dev/null; return 0; }
  chmod 644 "$tmp_file" 2>/dev/null || true
  mv -f "$tmp_file" "$output_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
  return 0
}

# Read the FIFO until keepalived closes it. A bad line must never kill this
# loop: if it dies, the .prom files keep their last value for ever.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^INSTANCE[[:space:]] ]] || continue

  line_clean="${line//\"/}"
  # The trailing _ swallows any extra field keepalived may add.
  read -r _ inst_name state priority _ <<< "$line_clean"

  [[ -n "$inst_name" && -n "$state" ]] || continue
  # An unreadable priority must not abort the arithmetic below.
  [[ "$priority" =~ ^[0-9]+$ ]] || priority=""

  case "$inst_name" in
    "$WRITER_INSTANCE") vip="$WRITER_VIP"; role="writer" ;;
    "$READER_INSTANCE") vip="$READER_VIP"; role="reader" ;;
    *) continue ;;
  esac

  case "$state" in
    # MASTER_PRIORITY comes from vrrp_notify_priority_changes, and
    # MASTER_RX_LOWER_PRI arrives when a master sees a lower-priority advert
    # (peer restart, split brain). In all three the node still holds the VIP.
    MASTER|MASTER_PRIORITY|MASTER_RX_LOWER_PRI)
      if [[ -n "$priority" && "$priority" -lt "$PRIORITY_THRESHOLD" ]]; then
        write_prom "$vip" "$role" 1
      else
        write_prom "$vip" "$role" 0
      fi
      ;;
    # BACKUP, BACKUP_PRIORITY, FAULT, STOP, DELETED: the VIP is not here.
    *)
      write_prom "$vip" "$role" 1
      ;;
  esac
done < "$FIFO_PATH"
