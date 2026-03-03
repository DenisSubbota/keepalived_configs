# Keepalived MySQL VIP POC
Proof of concept for using **Keepalived (VRRP)** to manage **MySQL Writer/Reader VIPs** in an async *primary → replica* topology.

---
Logic of the Keepalive IP controller 

# Writer VIP 
Node considered as healty Writer if next conditions are true:
- Node is writable: @@global.read_only=0
- Node is NOT a replica: no output from SHOW REPLICA STATUS/SHOW SLAVE STATUS (unless ALLOW_PRIMARY_AS_REPLICA=1)
Otherwise primary is considered as unhealthy, and no others primary candidates available: 
- Writer VIP is removed from interface
- ALERT RAISED for Writer VIP

# Reader VIP 
Node considered as healty Reader if next conditions are true:
- Node is read-only: @@global.read_only=1
- Node is Healthy replica: SQL and IO threads running (`Yes`) 
- Node has healthy replication lag: replication lag is below threshold: < `MAX_LAG_SECONDS` ( Default 300 seconds )
If replica node(s) considered as unhelaty:
- Reader VIP move to healty Writer instance, if no healty Writer available, VIP is removed from Interface.
- Triggers the alert for Reader VIP

## VIP assignment logic (current POC)
### Writer VIP

Writer VIP is assigned only when **all** are true:

- Node is writable: `@@global.read_only=0`
- Node is **not** a replica: no output from `SHOW REPLICA STATUS` / `SHOW SLAVE STATUS`

If the node is not eligible, Writer VIP should be removed.

**Caveat (single-replica setups):** If for any reason replication fails on the primary (e.g. the only replica disconnects, or replication breaks), conditions that depend on replication or node state can cause the writer check to fail and **remove the Writer VIP from that node**. With only one replica, this is risky: the VIP may move to the replica (which might not be ready for writes) or be lost, leaving applications without a writer. Prefer at least two replicas where possible, and monitor replication so you can fix or fail over in a controlled way.
Optional: If you want to allow a node to still qualify as Writer **even if it is configured as a replica**, add `--allow-primary-as-replica` to the script:

```conf
vrrp_script chk_mysql_writer {
    script "/etc/keepalived/check_mysql.sh --primary --allow-primary-as-replica"
    interval 5
    rise 2
    fall 2
}
```

### Reader VIP

Reader VIP is assigned only when **all** are true:

- Replication is healthy: IO + SQL threads running (`Yes`)
- Replication lag is below threshold: `Seconds_Behind_Source` / `Seconds_Behind_Master` < `MAX_LAG_SECONDS`
- Node is read-only: `@@global.read_only=1`

If no healthy replica is available, Reader VIP can fall back to the writer-eligible node.

## Script usage (`check_mysql.sh`)

One script covers all checks; everything is controlled by **flags** (no environment variables).

**Modes** (exactly one):

| Mode | Purpose |
|------|--------|
| `--primary` | Node must be writable primary: `read_only=0`, not configured as replica. Add `--allow-primary-as-replica` to allow primary even when configured as replica. |
| `--replica` | Node must be healthy replica: `read_only=1`, IO/SQL running, lag &lt; threshold. Use `--max-lag N` for threshold (default 300). |
| `--writer-or-reader` | Node is OK if it is either a healthy primary **or** a healthy replica (used for shared Reader VIP fallback). |

**Options** (all optional, pass as flags):

| Flag | Default | Description |
|------|---------|--------------|
| `--defaults-file` | `/home/percona/.my.cnf` | MySQL client option file (same as `mysql --defaults-file`). |
| `--mysql-bin` | `mysql` | Path to `mysql` binary. |
| `--max-lag` | `300` | Max replication lag (seconds) for `--replica`. |
| `--no-vip-file` | `/etc/keepalived/no_vip` | If this file exists, script exits 255 (do not claim VIP). |
| `--log-dir` | `/var/log/percona` | Log directory. |
| `--log-max-size` | `52428800` (50 MiB) | Rotate log when it exceeds this many bytes. |
| `--log-rotate-keep` | `7` | Number of rotated log files to keep. |
| `--allow-primary-as-replica` | off | For `--primary`: allow node even if configured as replica. |

Exit codes: **0** = passed, **1** = failed, **255** = do not claim VIP (e.g. `no_vip` file present). Run `check_mysql.sh --help` for a short summary.

## Configuration notes

- **Secrets**: The script uses a MySQL client option file (`--defaults-file`). That file must contain `[client]` with `user`, `password`, and connection (host/port or socket). Same format for MySQL, MariaDB, PXC, Percona.
- **Single script**: Copy `check_mysql.sh` to `/etc/keepalived/` and use it for all checks. Override defaults with flags, e.g. `--defaults-file /etc/mysql/my.cnf --no-vip-file /etc/keepalived/no_vip`.
- **Reader VIP fallback** (`chk_mysql_writer_or_reader`): Use `--writer-or-reader` so the node is OK as either writer (primary) or reader (replica). Pass the same options as your writer/reader checks for consistent behaviour: `--allow-primary-as-replica` if your writer check uses it, and `--max-lag N` to match your reader lag threshold. Example: `check_mysql.sh --writer-or-reader --allow-primary-as-replica --max-lag 300`.
- **no_vip**: If the file at `--no-vip-file` exists, the script exits 255. Use this to force a node to relinquish VIP (e.g. before maintenance).
- **Keepalived unicast**: configs are written for a 2-node unicast cluster; add more peers if needed.

## Logs

The health-check script writes a single log file: **`keepalived_check_mysql.log`** under the directory given by `--log-dir` (default **`/var/log/percona`**). Each line is timestamped (ISO 8601) and prefixed with the check mode: `[primary]`, `[replica]`, or `[writer_or_reader]`, so you can see which check ran and whether it passed or failed. **Rotation** is size-based: when the file reaches `--log-max-size` bytes (default **50 MiB**), the script renames it to `keepalived_check_mysql.log.1`, shifts existing `.1` → `.2`, and so on, keeping up to `--log-rotate-keep` files (default **7**). No external logrotate is required. Override location and behaviour with `--log-dir`, `--log-max-size`, and `--log-rotate-keep`. Example: `tail -f /var/log/percona/keepalived_check_mysql.log`.

## Alerting

Writer and Reader VIP state changes can be surfaced via the **notify handler** `keepalived_mysql_prom_handler.sh`. Call it with flags: `--state MASTER|FAULT --vip <ip> --cluster-virtual-ip-name <name>` and optional `--cluster <name>`. Example: `notify_master "/etc/keepalived/keepalived_mysql_prom_handler.sh --state MASTER --vip 192.168.88.18 --cluster-virtual-ip-name mysql_writer_vip"`. The handler writes **`gas_keepalived_mysql`** with labels `cluster`, `vip`, `Cluster_Virtual_IP_name`; value 0=healthy (MASTER), 1=failover_error (FAULT). Output: `PROM_OUTPUT_DIR/keepalived_mysql_<vip_sanitized>.prom` (mode 0644). Copy `keepalived_mysql_prom_handler.sh` to `/etc/keepalived/` and make it executable.

## Quick start (example)

1. Copy the node-specific config file to `/etc/keepalived/keepalived.conf` on each node.
2. Copy `check_mysql.sh` and `keepalived_mysql_prom_handler.sh` to `/etc/keepalived/` and make them executable.
3. Adjust:
   - Interface name (`interface`)
   - `unicast_src_ip` / `unicast_peer`
   - VIPs in `virtual_ipaddress`
   - `auth_pass`
   - For replica lag threshold use `--max-lag N` in the script (default 300)
4. Restart Keepalived and verify VIP assignment.
