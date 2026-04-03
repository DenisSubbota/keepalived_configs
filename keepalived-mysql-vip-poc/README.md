# Keepalived MySQL VIP POC

This project shows a simple way to keep stable MySQL client endpoints by using Keepalived and local MySQL health checks.

It manages two VIPs:

| VIP role | Normal owner | Fallback |
|----------|--------------|----------|
| Writer VIP | Writable MySQL node | Another node that becomes writable |
| Reader VIP | Healthy replica | The writer node if no healthy replica is available |

The configs in this repo are examples. Replace IPs, interface names, passwords, paths, and cluster labels to match your environment.

## What It Does

Each node runs Keepalived and the same health-check scripts.

Keepalived decides VIP ownership based on local MySQL state:

- Writer VIP stays on a node that is writable (`read_only=0`)
- Reader VIP prefers a healthy replica (`read_only=1`, replication running, lag below threshold)
- Reader VIP can fall back to the writer if no replica is healthy
- If a node is put into maintenance with `/etc/keepalived/no_vip`, it stops being eligible for VIP ownership

In this POC, the writer check is configured with `--allow-replica-except-from $KEEPALIVED_PEER_IP`. This allows a node with replication configured to hold the writer VIP, as long as it is not replicating from its peer. A node whose `Source_Host` matches the peer IP is treated as the downstream replica and will never win the writer VIP, even if it is temporarily writable.

## Repository Layout

| Path | Purpose |
|------|---------|
| `configs/` | Example Keepalived config for each node |
| `scripts/check_mysql.sh` | MySQL health-check script used by Keepalived |
| `scripts/keepalived_mysql_prom_handler.sh` | Optional notify script that writes Prometheus metrics |
| `alerts/` | Example alert rule |
| `tests/` | Manual failover scenarios and notes |

## Main Components

### 1. Keepalived

There are two VRRP instances:

- `VI_MYSQL_WRITER` manages the writer VIP
- `VI_MYSQL_READER` manages the reader VIP

The reader VIP is biased toward a healthy replica, but can still stay available on the writer when needed.

### 2. MySQL health check

`scripts/check_mysql.sh` supports three modes:

- `--primary`: checks whether the node can own the writer VIP; requires `read_only=0` and no replication configured, unless `--allow-replica-except-from` is used
- `--replica`: checks whether the node is a healthy replica
- `--writer-or-reader`: checks whether the node is valid for the reader VIP, either as replica or fallback writer

Important defaults:

- MySQL credentials file: `/home/percona/.my.cnf`
- Maintenance file: `/etc/keepalived/no_vip`
- Log file: `/var/log/percona/keepalived_check_mysql.log`
- Default max replica lag: `300` seconds

### 3. Optional monitoring hook

`scripts/keepalived_mysql_prom_handler.sh` is called from Keepalived notify hooks.

It writes Prometheus textfile metrics when a VIP enters an OK or FAIL state. If you do not need this, you can remove or replace the notify commands in the Keepalived config.

## Prerequisites

Before using this setup, make sure you have:

- Two Linux nodes with Keepalived installed
- MySQL running locally on each node
- A readable MySQL client credentials file for the check script
- Network connectivity between the Keepalived peers
- The correct network interface name in the config
- Chosen VIP addresses for writer and reader traffic

## Setup

### 1. Adapt the example config

Start from the files in `configs/` and update:

- `interface`
- `unicast_src_ip`
- `unicast_peer`
- `virtual_ipaddress`
- `auth_pass`
- notify script arguments such as `--vip` and `--cluster`

### 2. Install the files on each node

Typical layout:

```bash
sudo cp scripts/check_mysql.sh /etc/keepalived/check_mysql.sh
sudo cp scripts/keepalived_mysql_prom_handler.sh /etc/keepalived/keepalived_mysql_prom_handler.sh
sudo cp configs/keepalived.conf.node-<node-ip> /etc/keepalived/keepalived.conf
sudo chmod +x /etc/keepalived/check_mysql.sh /etc/keepalived/keepalived_mysql_prom_handler.sh
```

### 3. Make sure MySQL access works

The health-check script must be able to connect locally with the credentials file configured in `check_mysql.sh` or passed with `--defaults-file`.

Quick check:

```bash
mysql --defaults-file=/home/percona/.my.cnf -e "SELECT @@global.read_only;"
```

### 4. Start or restart Keepalived

```bash
sudo systemctl restart keepalived
sudo systemctl status keepalived --no-pager
```

## How To Validate

Check VIP placement:

```bash
ip addr show dev eth0
```

Check Keepalived logs:

```bash
sudo journalctl -u keepalived -n 50 --no-pager
```

Run the health checks manually (replace `<PEER_IP>` with the IP of the other Keepalived node):

```bash
/etc/keepalived/check_mysql.sh --primary --allow-replica-except-from <PEER_IP>
/etc/keepalived/check_mysql.sh --replica --max-lag 300
/etc/keepalived/check_mysql.sh --writer-or-reader --allow-replica-except-from <PEER_IP> --max-lag 300
echo $?
```

If monitoring is enabled, confirm `.prom` files are being written to the configured output directory.

## Expected Behavior

| Situation | Writer VIP | Reader VIP |
|-----------|------------|------------|
| Normal state | On writable node | On healthy replica |
| Replica unhealthy | Stays on writable node | Moves to writer if writer is healthy |
| Writer becomes read-only | Moves away or becomes unassigned | Can remain on healthy replica |
| Maintenance file present on a node | That node should give up VIPs | That node should give up VIPs |

## Troubleshooting

Useful commands:

```bash
systemctl status keepalived --no-pager
journalctl -u keepalived -f
tail -f /var/log/percona/keepalived_check_mysql.log
mysql --defaults-file=/home/percona/.my.cnf -e "SHOW REPLICA STATUS\G"
```

Things to check first:

- The MySQL credentials file is readable
- The local MySQL instance is reachable
- The configured interface name is correct
- The peer IPs are reachable
- `/etc/keepalived/no_vip` is not present unless you intentionally enabled maintenance mode

## Notes

- This repository is a POC, not a full production design
- The examples use unicast VRRP between two nodes
- The script supports both `SHOW REPLICA STATUS` and legacy `SHOW SLAVE STATUS`
- The example configs currently include a Prometheus notify hook, but that integration is optional
