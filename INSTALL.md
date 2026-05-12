# Installation

Step-by-step setup of the Keepalived MySQL VIP solution on a two-node source/replica pair. For an overview of the design, see [README.md](README.md).

All commands below assume you run them on **both** nodes unless explicitly stated otherwise.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Install keepalived](#2-install-keepalived)
3. [Install the scripts](#3-install-the-scripts)
4. [Create the MySQL check user](#4-create-the-mysql-check-user)
5. [Configure keepalived](#5-configure-keepalived)
6. [Choose sticky vs non-sticky VIPs](#6-choose-sticky-vs-non-sticky-vips)
7. [Verify the health checks](#7-verify-the-health-checks)
8. [Load the alert rule into PMM](#8-load-the-alert-rule-into-pmm)
9. [Start keepalived — primary node first](#9-start-keepalived--primary-node-first)
10. [Start keepalived — replica node](#10-start-keepalived--replica-node)
11. [Troubleshooting](#11-troubleshooting)

## 1. Prerequisites

- Two MySQL hosts with replication already configured and healthy.
- The PMM agent installed on each node, with its textfile-collector directory in place.
- VRRP traffic permitted between the two peers. The template uses unicast VRRP, which needs IP protocol `112` (VRRP) — not a TCP/UDP port — allowed in both directions between the two private IPs.

## 2. Install keepalived

Install the distro package on both nodes. Examples:

```bash
# RHEL / Rocky / Alma
sudo dnf install -y keepalived

# Debian / Ubuntu
sudo apt-get install -y keepalived
```

Confirm the version is 2.0 or newer:

```bash
keepalived -v
```

## 3. Install the scripts

From a clone of this repository, copy the two scripts to `/etc/keepalived/` on each node and make them executable:

```bash
sudo install -m 755 check_mysql.sh notify_fifo_handler.sh /etc/keepalived/
```

> Run from the repo root, or substitute full paths to each script.

## 4. Create the MySQL check user

The health check needs a MySQL user with `REPLICATION CLIENT` and `SELECT` privileges. Create it on the primary (it replicates to the replica):

```sql
CREATE USER 'keepalived'@'localhost' IDENTIFIED BY '<strong-password>';
GRANT REPLICATION CLIENT, SELECT ON *.* TO 'keepalived'@'localhost';
```

Then create a defaults-file the script can read non-interactively. The default location is `/home/percona/.my.cnf`:

```bash
sudo install -d -o root -g root -m 700 /home/percona
sudo tee /home/percona/.my.cnf >/dev/null <<'EOF'
[client]
user = keepalived
password = <strong-password>
EOF
sudo chmod 600 /home/percona/.my.cnf
```

> If you store credentials in a different path, pass it through `--defaults-file PATH` in every `vrrp_script` in `keepalived.conf`.

## 5. Configure keepalived

Copy [`keepalived.conf.template`](keepalived.conf.template) to `/etc/keepalived/keepalived.conf` on each node and replace the placeholders.

| Placeholder | Description |
|-------------|-------------|
| `KEEPALIVED_INTERFACE` | Interface that should carry the VIPs (e.g. `eth0`) |
| `KEEPALIVED_NODE_IP` | This host's private IP |
| `KEEPALIVED_PEER_IP` | The other peer's private IP |
| `KEEPALIVED_WRITER_VIP` | Writer VIP address |
| `KEEPALIVED_READER_VIP` | Reader VIP address |
| `KEEPALIVED_CLUSTER` | Cluster name (passed to the FIFO notifier; appears as a metric label) |
| `KEEPALIVED_MAX_LAG_SECONDS` | Maximum acceptable replication lag for the reader check |

Example values matching the template (swap `NODE` / `PEER` on the second host):

```text
KEEPALIVED_INTERFACE=eth0
KEEPALIVED_WRITER_VIP=10.20.30.101
KEEPALIVED_READER_VIP=10.20.30.102
KEEPALIVED_CLUSTER=cluster_app
KEEPALIVED_MAX_LAG_SECONDS=300
KEEPALIVED_NODE_IP=10.20.30.10
KEEPALIVED_PEER_IP=10.20.30.11
```

On the second node use `KEEPALIVED_NODE_IP=10.20.30.11` and `KEEPALIVED_PEER_IP=10.20.30.10`.

**Also on the second node:** the template ships with `state MASTER` on both `vrrp_instance` blocks for readability. `state` is only a hint for the initial transition — VRRP election is decided by `priority` and `track_script` weights — but it is conventional to set the writer instance to `state BACKUP` on the replica node and leave the reader instance as `state MASTER` there. The template's priorities (`10` on both, biased by weights) work correctly either way.

**Set a strong `auth_pass`** in both `vrrp_instance` blocks. It must match on both nodes for VRRP advertisements to be accepted.

## 6. Choose sticky vs non-sticky VIPs

- **Non-sticky (default).** The sticky `weight -5` lines stay commented with `#` so keepalived ignores them. Failed checks force `FAULT` and the VIP migrates immediately.
- **Sticky.** Uncomment the `weight -5` lines (delete the `#` before `chk_mysql_writer weight -5` and `chk_mysql_writer_or_reader weight -5`). Failed checks reduce priority instead of forcing `FAULT`, so the VIP can remain on the last-known node.

See the [VIP behaviour](README.md#vip-behaviour-sticky-vs-non-sticky) section of the README for the trade-off.

## 7. Verify the health checks

Run the checks as **root** (the same user keepalived will run them as). Exit code `0` means the node is healthy for that role.

**On the primary node:**

```bash
sudo /etc/keepalived/check_mysql.sh --primary --allow-replica-except-from <KEEPALIVED_PEER_IP>
echo $?
```

**On the replica node:**

```bash
sudo /etc/keepalived/check_mysql.sh --replica --max-lag <KEEPALIVED_MAX_LAG_SECONDS>
echo $?
```

Replace `<KEEPALIVED_PEER_IP>` and `<KEEPALIVED_MAX_LAG_SECONDS>` with the values you used in `keepalived.conf`. If the exit code is `1`, inspect `/var/log/percona/keepalived_check_mysql.log` for the reason.

## 8. Load the alert rule into PMM

The rule lives in [`keepalived-mysql-vip.alerts.yaml`](keepalived-mysql-vip.alerts.yaml) and fires when no node in a cluster reports a healthy VIP for one minute.

In PMM 2 / 3:

1. Open **Alerting → Alert rule templates** in the PMM UI.
2. Upload `keepalived-mysql-vip.alerts.yaml` (or copy its contents into a new rule).
3. Create an alert rule from the template `Percona_MS_KeepalivedMySQLVIPUnhealthy` and attach the notification channels you want to use.

Confirm `percona_keepalived_mysql` shows up under **Explore → Metrics** before you wire up the rule — if the metric is missing, the textfile collector isn't seeing the `.prom` files (see [Troubleshooting](#11-troubleshooting)).

## 9. Start keepalived — primary node first

On the node that should own the writer VIP:

```bash
sudo systemctl enable --now keepalived
ip a
```

With only one peer up, VRRP may place **both** VIPs on that node until the second peer starts and the election settles. Confirm with `ip a`.

## 10. Start keepalived — replica node

On the second node:

```bash
sudo systemctl enable --now keepalived
ip a
```

Once replication and both checks are healthy, the **reader** VIP should move to the replica; the **writer** VIP stays on the primary.

## 11. Troubleshooting

| Symptom | Where to look |
|---------|---------------|
| VIP doesn't show up anywhere | `journalctl -u keepalived` for VRRP state transitions; check that `unicast_src_ip` and `unicast_peer` are reachable on protocol 112 |
| Both nodes claim the same VIP (split brain) | `auth_pass` must match on both nodes; firewall must allow VRRP traffic in both directions |
| Check always fails | `cat /var/log/percona/keepalived_check_mysql.log` — the most recent line records the exact reason (read_only, lag, IO/SQL thread, etc.) |
| `no_vip` left behind | `ls /etc/keepalived/no_vip` — if it exists, the script forces exit `1` regardless of MySQL state. Remove it to re-enable. |
| No `percona_keepalived_mysql` metric | `ls /home/percona/pmm/collectors/textfile-collector/high-resolution/keepalived_mysql_*.prom` — files should exist after the first VRRP transition. Verify the PMM agent is configured to scrape that directory. |
| Script runs by hand but not from keepalived | keepalived runs scripts with a stripped `PATH` and as `script_user` (root in this template). Use absolute paths everywhere. |

To force a manual failover for testing, create the kill-switch on the current writer:

```bash
sudo touch /etc/keepalived/no_vip
# ... wait for fall * interval seconds ...
sudo rm /etc/keepalived/no_vip
```
