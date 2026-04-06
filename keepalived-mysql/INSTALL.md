# Installation

Deploy keepalived with separate writer and reader VIPs on two MySQL nodes. For behaviour, health checks, and sticky vs non-sticky VIPs, see [README.md](README.md).

## 1. Install keepalived

Install the keepalived package on **both** nodes.

## 2. Install scripts

From this repository, copy `scripts/check_mysql.sh` and `scripts/notify_fifo_handler.sh` to `/etc/keepalived/` on each node and make them executable:

```bash
sudo install -m 755 scripts/check_mysql.sh scripts/notify_fifo_handler.sh /etc/keepalived/
```

(Run from the repo root, or use full paths to the script files.)

## 3. Configure keepalived

Copy `configs/keepalived.conf.template` to `/etc/keepalived/keepalived.conf`.

The template uses placeholders in two forms: `$KEEPALIVED_*` (e.g. `interface`, `unicast`) and `${KEEPALIVED_*}` (e.g. `virtual_ipaddress`, `vrrp_script` command lines, `vrrp_notify_fifo_script`). **Use the same real values everywhere** after editing.

The lines at the top between the dashed comments (`$KEEPALIVED_INTERFACE=eth0`, and so on) are a **reference block only**: they are not valid keepalived directives. Either **delete that whole block** after you have substituted values, or replace every placeholder in the rest of the file with literals so the config is self-contained.

**Per node:** `KEEPALIVED_NODE_IP` must be **this host’s** IP and `KEEPALIVED_PEER_IP` must be **the other** keepalived node. All other placeholders (`WRITER_VIP`, `READER_VIP`, interface, cluster name, max lag) are normally the **same** on both nodes.


| Placeholder | Description |
|-------------|-------------|
| `KEEPALIVED_INTERFACE` | Interface that should carry the VIPs (e.g. `eth0`) |
| `KEEPALIVED_WRITER_VIP` | Writer VIP address |
| `KEEPALIVED_READER_VIP` | Reader VIP address |
| `KEEPALIVED_CLUSTER` | Cluster name (passed to the FIFO notifier for alerting) |
| `KEEPALIVED_MAX_LAG_SECONDS` | Maximum acceptable replication lag for the reader check |
| `KEEPALIVED_NODE_IP` | This host’s private IP |
| `KEEPALIVED_PEER_IP` | The other keepalived peer’s private IP |

Example values (adjust for your environment):

```text
KEEPALIVED_INTERFACE=eth0
KEEPALIVED_WRITER_VIP=192.168.88.18
KEEPALIVED_READER_VIP=192.168.88.19
KEEPALIVED_CLUSTER=mycluster
KEEPALIVED_MAX_LAG_SECONDS=300
KEEPALIVED_NODE_IP=10.30.50.115
KEEPALIVED_PEER_IP=10.30.50.117
```

Set a strong `auth_pass` in both `vrrp_instance` blocks instead of the template default.

## 4. Sticky vs non-sticky VIPs

- **Non-sticky (default in the template):** the `weight -5` lines stay **commented** with `!` so they are ignored.
- **Sticky:** **uncomment** those lines (delete the `!` before `chk_mysql_writer weight -5` and `chk_mysql_writer_or_reader weight -5`) so failed checks reduce priority instead of forcing FAULT.

See **VIP behaviour** in [README.md](README.md).

## 5. MySQL credentials for checks

Ensure the check can connect to MySQL non-interactively (for example `~percona/.my.cnf` for the monitoring user), as described under **Requirements** in the README.

## 6. Verify health checks

Run the checks as **root** (keepalived runs them as root). Exit code **0** means healthy for that role.

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

1. Load `alerts/keepalived-mysql-vip.alerts.yaml` into your PMM / Prometheus rule set as you usually do for custom alerts.
2. On **each** node, ensure the PMM agent’s **textfile collector** is enabled and that `notify_fifo_handler.sh` can write its output directory (default `/home/percona/pmm/collectors/textfile-collector/high-resolution`). Adjust ownership or pass `--prom-output-dir` in `vrrp_notify_fifo_script` if you use a different path.
3. After keepalived has run, confirm `.prom` files appear under that directory and show up in PMM for the node.

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
