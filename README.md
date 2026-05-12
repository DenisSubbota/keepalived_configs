# Keepalived MySQL VIP

A lightweight, Keepalived-based VIP failover solution for a two-node MySQL source/replica topology. Provides automatic writer and reader VIP placement based on MySQL health checks, with Prometheus-textfile observability scraped by the PMM agent.

## Contents

- [Requirements](#requirements)
- [Features](#features)
- [Repository layout](#repository-layout)
- [Topology](#topology)
- [Health checks (`check_mysql.sh`)](#health-checks-check_mysqlsh)
- [VIP behaviour: sticky vs non-sticky](#vip-behaviour-sticky-vs-non-sticky)
- [Observability and alerting](#observability-and-alerting)
- [Operational tools](#operational-tools)
- [Installation](#installation)

## Requirements

- Keepalived v2.0 or newer (uses `vrrp_notify_fifo`, `enable_script_security`)
- MySQL 5.7, 8.0, or 8.4 (community or Percona Server)
- A PMM agent on each node, with the textfile collector directory writable by the keepalived script user
- VRRP traffic permitted between the two peers (unicast VRRP uses IP protocol 112)

## Features

- **Automatic role detection.** Each node decides locally whether it can hold the writer or reader VIP using `check_mysql.sh`.
- **Sticky or non-sticky VIPs.** Pick whether a failed check drops the VIP (FAULT) or only nudges priority — see [VIP behaviour](#vip-behaviour-sticky-vs-non-sticky).
- **Replica-aware writer election.** The `--allow-replica-except-from` flag prevents a node that is replicating *from its peer* from being mistaken for the primary after failover.
- **Reader fallback.** If the replica is unhealthy, the reader VIP lands on the writer-capable node so applications keep their read endpoint.
- **Observability.** VRRP state changes are streamed through a FIFO to `notify_fifo_handler.sh`, which writes Prometheus textfile metrics scraped by the PMM agent. A ready-made alert rule is provided.
- **Operational kill-switch.** Creating `/etc/keepalived/no_vip` on a node forces all checks to fail, draining VIPs without stopping keepalived (useful for maintenance).

## Repository layout

| File | Purpose |
|------|---------|
| [`keepalived.conf.template`](keepalived.conf.template) | Reference keepalived config with placeholders for both VIP instances and all three `vrrp_script` blocks |
| [`check_mysql.sh`](check_mysql.sh) | Unified MySQL health check (writer / reader / writer-or-reader) used by `vrrp_script` |
| [`notify_fifo_handler.sh`](notify_fifo_handler.sh) | Reads the VRRP notify FIFO and writes Prometheus textfile metrics per VIP |
| [`keepalived-mysql-vip.alerts.yaml`](keepalived-mysql-vip.alerts.yaml) | PMM/Prometheus alerting rule that fires when a node cannot hold any VIP |
| [`INSTALL.md`](INSTALL.md) | Step-by-step installation and verification guide |

## Topology

```text
                    ┌────────────────────────────────┐
                    │      PMM-server / Alerting     │
                    └───────┬────────────────┬───────┘
                            │                │
      ┌─────────────────────┘                └─────────────────────┐
      │               ┌──────────────────────────┐                 │
      │               │        Application       │                 │
      │               └─────┬──────────────┬─────┘                 │
      │                     │              │                       │
      │             ┌───────┘              └───────┐               │
      │             │ Write                  Read  │               │
      │  [db1]      ▼                              ▼      [db2]    │
      │  ┌───────────────────┐             ┌───────────────────┐   │
      │  │    Writer VIP     │◄───────────►│    Reader VIP     │   │
      │  │   [keepalived]    │    VRRP     │   [keepalived]    │   │
      │  ├───────────────────┤             ├───────────────────┤   │
      │  │    MySQL [rw]     │ Replication │    MySQL [ro]     │   │
      │  │  <Private IP 1>   ├────────────►│  <Private IP 2>   │   │
      │  ├───────────────────┤             ├───────────────────┤   │
      └─►│     pmm-agent     │             │     pmm-agent     │◄──┘
         └───────────────────┘             └───────────────────┘
```

Each node runs keepalived with two `vrrp_instance` blocks — one for the writer VIP and one for the reader VIP. Priorities and `track_script` weights determine which node currently owns each address.

## Health checks (`check_mysql.sh`)

The script decides whether a node may hold the writer or reader VIP. Exit code `0` means healthy for the requested role; `1` means unhealthy.

Before running any role-specific logic the script also fails if `/etc/keepalived/no_vip` exists or if the MySQL defaults-file is unreadable — see [Operational tools](#operational-tools).

### Writer (`--primary`)

- `@@global.read_only = 0`
- Without `--allow-replica-except-from`: no replication channel may be configured
- With `--allow-replica-except-from PEER_IP`: replication is tolerated **unless** `Source_Host` / `Master_Host` equals `PEER_IP`, so a node still replicating *from its peer* is never treated as the primary

```bash
/etc/keepalived/check_mysql.sh --primary --allow-replica-except-from "${KEEPALIVED_PEER_IP}"
```

### Reader (`--replica`)

- `SHOW REPLICA STATUS` / `SHOW SLAVE STATUS` returns rows
- `@@global.read_only = 1`
- IO and SQL threads both `Yes`
- `Seconds_Behind_Source` / `Seconds_Behind_Master` strictly **less** than `--max-lag` (default `300`)

```bash
/etc/keepalived/check_mysql.sh --replica --max-lag "${KEEPALIVED_MAX_LAG_SECONDS}"
```

### Writer-or-reader (`--writer-or-reader`)

Used so the reader VIP can fall back to the writer-capable node when the replica is unhealthy. Passes if **either** the primary or replica check passes; supply the same extra flags you use for `--primary` and `--replica`.

```bash
/etc/keepalived/check_mysql.sh --writer-or-reader \
  --allow-replica-except-from "${KEEPALIVED_PEER_IP}" \
  --max-lag "${KEEPALIVED_MAX_LAG_SECONDS}"
```

### Required MySQL privileges

The check runs `SELECT @@global.read_only` and `SHOW REPLICA STATUS` (or the legacy `SHOW SLAVE STATUS`). A user with the following grants is sufficient:

```sql
CREATE USER 'keepalived'@'localhost' IDENTIFIED BY '<strong-password>';
GRANT REPLICATION CLIENT, SELECT ON *.* TO 'keepalived'@'localhost';
```

> `REPLICATION CLIENT` is required for `SHOW REPLICA STATUS`. On MySQL 8.0.22+ the equivalent privilege is `REPLICATION_SLAVE_ADMIN` / `REPLICATION CLIENT` (the old name still works).

Place the credentials in the file referenced by `--defaults-file` (default `/home/percona/.my.cnf`), readable only by `root`:

```ini
[client]
user = keepalived
password = <strong-password>
```

### All options

| Flag | Description | Default |
|------|-------------|---------|
| `--primary` / `--replica` / `--writer-or-reader` | Mode selector (exactly one required) | — |
| `--defaults-file PATH` | MySQL client options file | `/home/percona/.my.cnf` |
| `--mysql-bin PATH` | `mysql` binary | `mysql` |
| `--max-lag N` | Max replica lag in seconds (`--replica` and `--writer-or-reader`) | `300` |
| `--allow-replica-except-from IP` | Tolerate replication on the primary check unless `Source_Host` matches `IP` | unset |
| `--no-vip-file PATH` | Existence of this file forces the check to fail | `/etc/keepalived/no_vip` |
| `--log-dir DIR` | Log directory | `/var/log/percona` |
| `--log-max-size N` | Rotate when log exceeds N bytes | `52428800` (50 MiB) |
| `--log-rotate-keep N` | Keep N rotated files | `7` |

Logs land in `${LOG_DIR}/keepalived_check_mysql.log` and are rotated by the script itself — no `logrotate` config required.

## VIP behaviour: sticky vs non-sticky

A Keepalived `track_script` entry with **no weight** (the default) treats every failed run as a hard fault: after `fall` failures the VRRP instance enters **FAULT** and the VIP is removed. Adding a **non-zero weight** instead adds (or subtracts) from the instance priority on each success/failure, which lets the VIP stay put even when checks fail. See `vrrp_script` and `track_script` in `keepalived.conf(5)`.

### Non-sticky (default in the template)

A VIP must leave a node that is unhealthy for that role.

- **`VI_MYSQL_WRITER`** — track only `chk_mysql_writer` with no weight (failure ⇒ FAULT).
- **`VI_MYSQL_READER`** — track `chk_mysql_writer_or_reader` with no weight (failure ⇒ FAULT when *neither* role is healthy). Weighted `chk_mysql_writer` and `chk_mysql_reader` entries bias the election so a healthy replica is preferred over the writer for the reader VIP.

```text
vrrp_instance VI_MYSQL_WRITER {
    ...
    track_script {
        chk_mysql_writer
    }
}

vrrp_instance VI_MYSQL_READER {
    ...
    track_script {
        chk_mysql_writer weight 5
        chk_mysql_reader weight 10
        chk_mysql_writer_or_reader
    }
}
```

### Sticky

Similar in spirit to the legacy `ip_controller` flow: the VIP **remains** on the last node while checks fail, and alerting still fires. In `keepalived.conf.template`, **uncomment** the sticky-mode `weight -5` lines (remove the leading `#` so keepalived sees `chk_mysql_writer weight -5` and `chk_mysql_writer_or_reader weight -5`) so those scripts adjust priority instead of forcing FAULT.

```text
vrrp_instance VI_MYSQL_WRITER {
    ...
    track_script {
        chk_mysql_writer weight -5
    }
}

vrrp_instance VI_MYSQL_READER {
    ...
    track_script {
        chk_mysql_writer weight 5
        chk_mysql_reader weight 10
        chk_mysql_writer_or_reader weight -5
    }
}
```

## Observability and alerting

Keepalived publishes VRRP state and priority changes to a FIFO (`vrrp_notify_fifo` in the template). [`notify_fifo_handler.sh`](notify_fifo_handler.sh) consumes the FIFO and writes one Prometheus textfile per VIP:

```
${PROM_OUTPUT_DIR}/keepalived_mysql_<vip>.prom
```

Default output directory: `/home/percona/pmm/collectors/textfile-collector/high-resolution` (override with `--prom-output-dir`). The PMM agent scrapes this directory like any other textfile collector target.

Each file exposes two series:

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `percona_keepalived_mysql` | untyped | `cluster`, `vip`, `role` | `0` = node currently holds the VIP and is healthy for that role; `1` = node does not, or VIP is unhealthy |
| `percona_keepalived_mysql_last_report_ts` | untyped | same as above | Unix timestamp of the last FIFO event for this VIP |

### Notify-handler options

| Flag | Description | Default |
|------|-------------|---------|
| `--cluster NAME` | Cluster label applied to all metrics | required |
| `--writer-vip IP` | Writer VIP address (label and file name) | required |
| `--reader-vip IP` | Reader VIP address (label and file name) | required |
| `--priority-threshold N` | A `MASTER` / `MASTER_PRIORITY` state with priority below this value is reported as unhealthy (`1`). Useful in sticky mode where a node keeps the VIP at reduced priority. | `10` |
| `--prom-output-dir DIR` | Output directory for the `.prom` files | `/home/percona/pmm/collectors/textfile-collector/high-resolution` |

### Alert rule

[`keepalived-mysql-vip.alerts.yaml`](keepalived-mysql-vip.alerts.yaml) defines `Percona_MS_KeepalivedMySQLVIPUnhealthy`, which fires when no node in a cluster is reporting a healthy VIP for at least one minute.

## Operational tools

### Maintenance kill-switch (`no_vip`)

Drain VIPs from a node without stopping keepalived:

```bash
sudo touch /etc/keepalived/no_vip
```

Every invocation of `check_mysql.sh` exits `1` while the file exists, so both VIPs leave the node on the next failure window. Remove the file to re-enable:

```bash
sudo rm /etc/keepalived/no_vip
```

The path can be customised per `vrrp_script` with `--no-vip-file`.

### Logs

| File | Written by |
|------|------------|
| `/var/log/percona/keepalived_check_mysql.log` | `check_mysql.sh` (every health-check decision, with reason on failure) |
| `journalctl -u keepalived` | keepalived itself (state transitions, script timeouts) |
| `${PROM_OUTPUT_DIR}/keepalived_mysql_<vip>.prom` | `notify_fifo_handler.sh` (metric snapshot) |

## Installation

See [INSTALL.md](INSTALL.md) for the step-by-step guide.
