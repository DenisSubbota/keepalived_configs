# Installation
For general info about solution see [README.md](README.md).

## 1. Install keepalived

Install the keepalived package on **both** nodes.

## 2. Install scripts

From this repository, copy `check_mysql.sh` and `notify_fifo_handler.sh` to `/etc/keepalived/` on each node and make them executable:

```bash
sudo install -m 755 check_mysql.sh notify_fifo_handler.sh /etc/keepalived/
```

(Run from the repo root, or use full paths to the script files.)

## 3. Configure keepalived

Copy `keepalived.conf.template` to `/etc/keepalived/keepalived.conf`.

Replace every placeholder with your values (see the table below).

| Placeholder | Description |
|-------------|-------------|
| `KEEPALIVED_INTERFACE` | Interface that should carry the VIPs (e.g. `eth0`) |
| `KEEPALIVED_WRITER_VIP` | Writer VIP address |
| `KEEPALIVED_READER_VIP` | Reader VIP address |
| `KEEPALIVED_CLUSTER` | Cluster name (passed to the FIFO notifier for alerting) |
| `KEEPALIVED_MAX_LAG_SECONDS` | Maximum acceptable replication lag for the reader check |
| `KEEPALIVED_NODE_IP` | This host’s private IP |
| `KEEPALIVED_PEER_IP` | The other keepalived peer’s private IP |

Example values matching the reference block in `keepalived.conf.template` (swap `NODE` / `PEER` on the second host):

```text
KEEPALIVED_INTERFACE=eth0
KEEPALIVED_WRITER_VIP=10.20.30.101
KEEPALIVED_READER_VIP=10.20.30.102
KEEPALIVED_CLUSTER=cluster_app
KEEPALIVED_MAX_LAG_SECONDS=300
KEEPALIVED_NODE_IP=10.20.30.10
KEEPALIVED_PEER_IP=10.20.30.11
```
On the other node use `KEEPALIVED_NODE_IP=10.20.30.11` and `KEEPALIVED_PEER_IP=10.20.30.10`.

Set a strong `auth_pass` in both `vrrp_instance` blocks instead of the template default.

## 4. Sticky vs non-sticky VIPs

- **Non-sticky (default in the template):** the `weight -5` lines stay **commented** with `!` so they are ignored.
- **Sticky:** **uncomment** those lines (delete the `!` before `chk_mysql_writer weight -5` and `chk_mysql_writer_or_reader weight -5`) so failed checks reduce priority instead of forcing FAULT.

See **VIP behaviour** in [README.md](README.md).

## 5. MySQL credentials for checks

Ensure the check can connect to MySQL non-interactively using `/home/percona/.my.cnf` file

## 6. Verify health checks

Run the checks as **root**. Exit code **0** means healthy for that role.

**On the primary (writer) node:**

```bash
sudo /etc/keepalived/check_mysql.sh --primary --allow-replica-except-from <KEEPALIVED_PEER_IP>
echo $?
```

**On the replica node:**

```bash
sudo /etc/keepalived/check_mysql.sh --replica --max-lag <KEEPALIVED_MAX_LAG_SECONDS>
echo $?
```

Replace `KEEPALIVED_PEER_IP` and `KEEPALIVED_MAX_LAG_SECONDS` with the same values you use in `keepalived.conf`.

## 7. Alerting
Create alert `Percona_MS_KeepalivedMySQLVIPUnhealthy` using `keepalived-mysql-vip.alerts.yaml` file from repo into PMM-server 

## 8. Start keepalived — primary first

On the node that should own the writer VIP first:

```bash
sudo systemctl enable --now keepalived
ip a
```

With only one peer up, VRRP may place **both** VIPs on that node until the second node starts and priorities/election settle—confirm with `ip a` and your application expectations.

## 9. Start keepalived — replica

On the second node:

```bash
sudo systemctl enable --now keepalived
ip a
```
When replication and checks are healthy, the **reader** VIP should move to the replica; the **writer** VIP should stay on the primary.