# Keepalived MySQL VIP POC

Proof of concept for using **Keepalived (VRRP)** to manage **MySQL Writer/Reader VIPs** in an async *primary → replica* topology.

## Repo layout

- `configs/`
  - `keepalived.conf.node-10.30.50.115` (example)
  - `keepalived.conf.node-10.30.50.117` (example)
- `scripts/`
  - `check_mysql_writer.sh` (writer eligibility check)
  - `check_mysql_reader.sh` (reader eligibility check)
- `tests/`
  - `scenarios.md` (manual test scenarios + collected outputs/logs)
- `TODO.md`

## VIP assignment logic (current POC)

### Writer VIP

Writer VIP is assigned only when **all** are true:

- Node is writable: `@@global.read_only=0` and `@@global.super_read_only=0`
- Node is **not** a replica: no output from `SHOW REPLICA STATUS` / `SHOW SLAVE STATUS`
- At least one replica is attached: non-empty `SHOW REPLICAS` (8.x) or `SHOW SLAVE HOSTS` (5.7/8.0)

If the node is not eligible, Writer VIP should be removed.

Optional behavior:

- If you want to allow a node to still qualify as Writer **even if it is configured as a replica**, set `ALLOW_PRIMARY_AS_REPLICA=1` for the writer check script.
  - Example in Keepalived config:

```conf
vrrp_script chk_mysql_writer {
    script "/bin/sh -c 'ALLOW_PRIMARY_AS_REPLICA=1 /etc/keepalived/check_mysql_writer.sh'"
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

## Configuration notes

- **Secrets**: config examples include `auth_pass` and scripts include default MySQL credentials as POC defaults. Override via environment variables and/or update configs before real usage.
- **Keepalived unicast**: configs are written for a 2-node unicast cluster; add more peers if needed.

## Quick start (example)

1. Copy the node-specific config file to `/etc/keepalived/keepalived.conf` on each node.
2. Copy scripts to `/etc/keepalived/` and make them executable.
3. Adjust:
   - Interface name (`interface`)
   - `unicast_src_ip` / `unicast_peer`
   - VIPs in `virtual_ipaddress`
   - `auth_pass`
   - `MAX_LAG_SECONDS` (reader)
4. Restart Keepalived and verify VIP assignment.

