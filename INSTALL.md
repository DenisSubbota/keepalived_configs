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

- Two MySQL hosts with replication already configured and healthy. Point the replica at the primary's **IP**, not a hostname — the writer check compares `Source_Host` with the peer IP as plain text.
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

Confirm the version is 2.0.7 or newer — older builds mis-parse the `$VARIABLE=value` lines in the template:

```bash
keepalived -v
```

## 3. Install the scripts

From a clone of this repository, copy the two scripts to `/etc/keepalived/` on each node:

```bash
sudo install -o root -g root -m 755 check_mysql.sh notify_fifo_handler.sh /etc/keepalived/
```

> Run from the repo root, or substitute full paths to each script.

The template sets `enable_script_security` with `script_user root`. Keepalived then walks the whole path of each script and refuses to run it if any part is not root-owned or is group- or world-writable. Check it once:

```bash
ls -ld / /etc /etc/keepalived /etc/keepalived/check_mysql.sh /etc/keepalived/notify_fifo_handler.sh
```

Everything on that list must be owned by `root` and show no `w` for group or other.

Optional, on a workstation or either node: run the offline test suite from the repo to confirm the scripts behave before they are wired into keepalived.

```bash
bash tests/run_offline_tests.sh
```

## 4. Create the MySQL check user

The health check needs a MySQL user with the `REPLICATION CLIENT` privilege. Create it on the primary (it replicates to the replica):

```sql
CREATE USER 'keepalived'@'localhost' IDENTIFIED BY '<strong-password>';
GRANT REPLICATION CLIENT ON *.* TO 'keepalived'@'localhost';
```

> No `SELECT` grant is needed: reading `@@global.read_only` requires no privilege.

Then create the option file the script reads. Keep it in `/etc/keepalived`, owned by root:

```bash
sudo tee /etc/keepalived/.my.cnf >/dev/null <<'EOF'
[client]
user = keepalived
password = <strong-password>
EOF
sudo chown root:root /etc/keepalived/.my.cnf
sudo chmod 600 /etc/keepalived/.my.cnf
```

> **Do not put this file in another user's home directory.** Keepalived runs the check as `root`, and whoever owns that home can replace the file and so control the options root hands to the `mysql` client. The script's built-in default is still `/home/percona/.my.cnf` for older installs; the template overrides it with `--defaults-file`.

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
| `KEEPALIVED_MYSQL_CNF` | MySQL option file with the check user credentials |
| `KEEPALIVED_PRIORITY` | Base VRRP priority — the **same value on both nodes** |
| `KEEPALIVED_AUTH_PASS` | VRRP shared secret — the same on both nodes |
| `KEEPALIVED_WRITER_ROUTER_ID` / `KEEPALIVED_READER_ROUTER_ID` | VRRP router IDs, unique per L2 segment |

Example values matching the template (swap `NODE` / `PEER` on the second host):

```text
KEEPALIVED_INTERFACE=eth0
KEEPALIVED_WRITER_VIP=10.20.30.101
KEEPALIVED_READER_VIP=10.20.30.102
KEEPALIVED_CLUSTER=cluster_app
KEEPALIVED_MAX_LAG_SECONDS=300
KEEPALIVED_MYSQL_CNF=/etc/keepalived/.my.cnf
KEEPALIVED_PRIORITY=10
KEEPALIVED_NODE_IP=10.20.30.10
KEEPALIVED_PEER_IP=10.20.30.11
```

On the second node use `KEEPALIVED_NODE_IP=10.20.30.11` and `KEEPALIVED_PEER_IP=10.20.30.10`.

**Keep `KEEPALIVED_PRIORITY` identical on both nodes.** The reader VIP is placed by `track_script` weights (`+10` healthy replica, `+5` healthy writer). A different base priority per node would outweigh that and pin the reader VIP to the wrong host.

**`state` on the second node.** The template ships `state MASTER` on the writer instance and `state BACKUP` on the reader instance. `state` is only a hint for the first transition — the election is decided by `priority` and the `track_script` weights — but set the **writer** instance to `state BACKUP` on the replica node so the roles read the way they behave.

**Set `KEEPALIVED_AUTH_PASS`** to the same value on both nodes. VRRP uses only the **first 8 characters**; a longer secret is silently truncated, so pick 8 characters that matter.

## 6. Choose sticky vs non-sticky VIPs

- **Non-sticky (default).** The sticky `weight -5` lines stay commented with `#` so keepalived ignores them. Failed checks force `FAULT` and the VIP migrates immediately.
- **Sticky.** Uncomment the `weight -5` lines (delete the `#` before `chk_mysql_writer weight -5` and `chk_mysql_writer_or_reader weight -5`). Failed checks reduce priority instead of forcing `FAULT`, so the VIP can remain on the last-known node.

Sticky mode relies on `--priority-threshold` matching `KEEPALIVED_PRIORITY` so the metric still reports the node as unhealthy. The template passes `--priority-threshold ${KEEPALIVED_PRIORITY}` for you; keep them in step if you change either one.

See the [VIP behaviour](README.md#vip-behaviour-sticky-vs-non-sticky) section of the README for the trade-off.

## 7. Verify the health checks

Run the checks as **root** (the same user keepalived will run them as). Exit `0` means the node is healthy for that role, `1` unhealthy, `2` a bad option.

**On the primary node:**

```bash
sudo /etc/keepalived/check_mysql.sh --primary \
  --defaults-file /etc/keepalived/.my.cnf \
  --allow-replica-except-from <KEEPALIVED_PEER_IP>
echo $?
```

**On the replica node:**

```bash
sudo /etc/keepalived/check_mysql.sh --replica \
  --defaults-file /etc/keepalived/.my.cnf \
  --max-lag <KEEPALIVED_MAX_LAG_SECONDS>
echo $?
```

Replace `<KEEPALIVED_PEER_IP>` and `<KEEPALIVED_MAX_LAG_SECONDS>` with the values you used in `keepalived.conf`. If the exit code is `1`, inspect `/var/log/percona/keepalived_check_mysql.log` for the reason. Exit code `2` means the command line itself is wrong — fix it before starting keepalived, because keepalived would read it as a failed check and drop the VIP.

## 8. Load the alert rule into PMM

[`keepalived-mysql-vip.alerts.yaml`](keepalived-mysql-vip.alerts.yaml) is a PMM **alert rule template** (root key `templates:`). It fires when a node reports neither a writer nor a reader VIP for one minute.

In PMM 2 / 3:

1. Open **Alerting → Alert rule templates** in the PMM UI and click **Add template**, then paste or upload `keepalived-mysql-vip.alerts.yaml`. As an alternative, copy the file into `/srv/alerting/templates/` on the PMM server and restart PMM — it loads templates from there at startup.
2. Go to **Alerting → Alert rules → New alert rule from template** and pick `Percona_MS_KeepalivedMySQLVIPUnhealthy`.
3. Choose the folder, set the node/service filters you want, and attach the notification channels.

Confirm `percona_keepalived_mysql` shows up under **Explore → Metrics** before you wire up the rule — if the metric is missing, the textfile collector isn't seeing the `.prom` files (see [Troubleshooting](#11-troubleshooting)).

## 9. Start keepalived — primary node first

On the node that should own the writer VIP:

```bash
sudo systemctl enable --now keepalived
ip a
```

With `init_fail` on the tracking scripts, each VRRP instance stays in FAULT until its check has passed twice (about 10 seconds), so give it that long before judging. With only one peer up, VRRP may place **both** VIPs on that node until the second peer starts and the election settles. Confirm with `ip a`.

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
| Both nodes claim the same VIP (split brain) | `auth_pass` must match on both nodes — remember only the first 8 characters count; firewall must allow VRRP traffic in both directions |
| Checks never run at all | `journalctl -u keepalived \| grep -i 'unsafe permissions\|disabling'` — with `enable_script_security` keepalived disables a root script whose path is writable by a non-root user. Fix ownership as in [step 3](#3-install-the-scripts) |
| Check always fails | `cat /var/log/percona/keepalived_check_mysql.log` — the most recent line records the exact reason (read_only, lag, IO/SQL thread, MySQL error text) |
| Check exits `2` | A bad option in `keepalived.conf`: wrong flag name, missing value, or a `$KEEPALIVED_*` variable that did not get substituted. The same log file records `usage error: ...` |
| Writer check fails on the real primary | It is replicating from the peer IP, or replication is configured with a hostname the check cannot match. See [Writer](README.md#writer---primary) |
| `no_vip` left behind | `ls /etc/keepalived/no_vip` — if it exists, the script forces exit `1` regardless of MySQL state. Remove it to re-enable |
| No `percona_keepalived_mysql` metric | `ls /home/percona/pmm/collectors/textfile-collector/high-resolution/keepalived_mysql_*.prom` — files should exist after the first VRRP transition. Verify the PMM agent is configured to scrape that directory, and check the handler's startup line in `journalctl -u keepalived` |
| Metric stuck on an old value | The handler only writes on VRRP events. If keepalived is stopped the last values stay on disk — check `systemctl status keepalived` too |
| Script runs by hand but not from keepalived | keepalived runs scripts with a stripped `PATH` and as `script_user` (root in this template). Use absolute paths everywhere |

To force a manual failover for testing, create the kill-switch on the current writer:

```bash
sudo touch /etc/keepalived/no_vip
# ... wait for fall * interval seconds (10s with the template defaults) ...
sudo rm /etc/keepalived/no_vip
```
