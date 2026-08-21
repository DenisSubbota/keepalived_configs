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
- [Known limits](#known-limits)
- [Tests](#tests)
- [Installation](#installation)

## Requirements

- Keepalived 2.0.7 or newer. The `$VARIABLE=value` substitution in the template arrived in 1.4.0 and its last parsing bugs were fixed in 2.0.7; `vrrp_notify_fifo` needs 2.0 or newer.
- MySQL 5.7, 8.0, or 8.4 (community or Percona Server)
- A PMM agent on each node, with the textfile collector directory writable by the keepalived script user
- VRRP traffic permitted between the two peers (unicast VRRP uses IP protocol 112)

## Features

- **Automatic role detection.** Each node decides locally whether it can hold the writer or reader VIP using `check_mysql.sh`.
- **Sticky or non-sticky VIPs.** Pick whether a failed check drops the VIP (FAULT) or only nudges priority — see [VIP behaviour](#vip-behaviour-sticky-vs-non-sticky).
- **Replica-aware writer election.** The `--allow-replica-except-from` flag prevents a node that is replicating *from its peer* from being mistaken for the primary after failover.
- **Reader fallback.** If the replica is unhealthy, the reader VIP lands on the writer-capable node so applications keep their read endpoint.
- **Observability.** VRRP state changes are streamed through a FIFO to `notify_fifo_handler.sh`, which writes Prometheus textfile metrics scraped by the PMM agent. A ready-made PMM alert template is provided.
- **Operational kill-switch.** Creating `/etc/keepalived/no_vip` on a node forces all checks to fail, draining VIPs without stopping keepalived (useful for maintenance).

## Repository layout

| File | Purpose |
|------|---------|
| [`keepalived.conf.template`](keepalived.conf.template) | Reference keepalived config with placeholders for both VIP instances and all three `vrrp_script` blocks |
| [`check_mysql.sh`](check_mysql.sh) | Unified MySQL health check (writer / reader / writer-or-reader) used by `vrrp_script` |
| [`notify_fifo_handler.sh`](notify_fifo_handler.sh) | Reads the VRRP notify FIFO and writes Prometheus textfile metrics per VIP |
| [`keepalived-mysql-vip.alerts.yaml`](keepalived-mysql-vip.alerts.yaml) | PMM alert rule template that fires when a node cannot hold any VIP |
| [`tests/run_offline_tests.sh`](tests/run_offline_tests.sh) | Offline tests for both scripts — no MySQL and no keepalived needed |
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

### Priorities

Both nodes use the **same** base `priority` (`$KEEPALIVED_PRIORITY`, default `10`). The reader VIP is placed by the `track_script` weights: a healthy replica adds `+10`, a healthy writer adds `+5`, so the replica wins with 20 against 15.

Do not give the two nodes different base priorities, even though `keepalived.conf(5)` recommends that in general. A gap larger than 5 would outweigh the reader preference and pin the reader VIP to whichever node has the higher base value. See [Known limits](#known-limits) for what this costs.

## Health checks (`check_mysql.sh`)

The script decides whether a node may hold the writer or reader VIP.

| Exit code | Meaning |
|-----------|---------|
| `0` | Healthy for the requested role |
| `1` | Not healthy for the requested role |
| `2` | Usage or config error (bad flag, missing value, non-numeric number) |

Keepalived treats anything non-zero as a failed check, so a config typo drops the VIP rather than passing silently — run the checks by hand once after install (see [INSTALL.md](INSTALL.md#7-verify-the-health-checks)).

Before running any role-specific logic the script also fails if `/etc/keepalived/no_vip` exists or if the MySQL defaults-file is unreadable — see [Operational tools](#operational-tools).

### Writer (`--primary`)

- `@@global.read_only = 0`
- Without `--allow-replica-except-from`: no replication channel may be configured
- With `--allow-replica-except-from PEER_IP`: replication is tolerated **unless** `Source_Host` / `Master_Host` equals `PEER_IP`, so a node still replicating *from its peer* is never treated as the primary
- If replication is configured but `Source_Host` cannot be read at all, the check fails: it cannot show the node is not following its peer

The comparison is a plain string match. If replication was set up with a hostname, `Source_Host` holds that hostname and it will not match the peer's IP — configure replication with the same IP you put in `$KEEPALIVED_PEER_IP`.

```bash
/etc/keepalived/check_mysql.sh --primary --allow-replica-except-from "${KEEPALIVED_PEER_IP}"
```

### Reader (`--replica`)

- `SHOW REPLICA STATUS` / `SHOW SLAVE STATUS` returns rows
- `@@global.read_only = 1`
- IO and SQL threads both `Yes`
- `Seconds_Behind_Source` / `Seconds_Behind_Master` strictly **less** than `--max-lag` (default `300`). `NULL` — replication stopped — counts as failed

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

Each run asks MySQL for `read_only` and the replica status once and reuses the answers, so `--writer-or-reader` is no slower than a single-role check.

### Required MySQL privileges

The check runs `SELECT @@global.read_only` and `SHOW REPLICA STATUS` (or the legacy `SHOW SLAVE STATUS`):

```sql
CREATE USER 'keepalived'@'localhost' IDENTIFIED BY '<strong-password>';
GRANT REPLICATION CLIENT ON *.* TO 'keepalived'@'localhost';
```

> `SHOW REPLICA STATUS` needs `REPLICATION CLIENT` (or the deprecated `SUPER`) on 5.7, 8.0 and 8.4 alike — `REPLICATION_SLAVE_ADMIN` does not cover it. Reading `@@global.read_only` needs no privilege at all, so no `SELECT` grant is required.

Place the credentials in the file referenced by `--defaults-file`:

```ini
[client]
user = keepalived
password = <strong-password>
```

The template points `--defaults-file` at `/etc/keepalived/.my.cnf`, root-owned and mode `600`. **Do not keep this file in another user's home directory.** Keepalived runs the check as `root`; the owner of that home can replace the file and so choose the options root passes to the `mysql` client. The script's built-in default is still `/home/percona/.my.cnf` for older installs, but new deployments should use the path in the template.

### All options

| Flag | Description | Default |
|------|-------------|---------|
| `--primary` / `--replica` / `--writer-or-reader` | Mode selector (exactly one required) | — |
| `--defaults-file PATH` | MySQL client options file | `/home/percona/.my.cnf` |
| `--mysql-bin PATH` | `mysql` binary | `mysql` |
| `--connect-timeout N` | MySQL client connect timeout in seconds | `3` |
| `--max-lag N` | Max replica lag in seconds (`--replica` and `--writer-or-reader`) | `300` |
| `--allow-replica-except-from IP` | Tolerate replication on the primary check unless `Source_Host` matches `IP` (`--primary` and `--writer-or-reader`) | unset |
| `--no-vip-file PATH` | Existence of this file forces the check to fail | `/etc/keepalived/no_vip` |
| `--log-dir DIR` | Log directory | `/var/log/percona` |
| `--log-max-size N` | Rotate when log exceeds N bytes | `52428800` (50 MiB) |
| `--log-rotate-keep N` | Keep N rotated files | `7` |
| `-h`, `--help` | Print the option list | — |

Logs land in `${LOG_DIR}/keepalived_check_mysql.log` and are rotated by the script itself — no `logrotate` config required.

## VIP behaviour: sticky vs non-sticky

A Keepalived `track_script` entry with **no weight** (the default) treats every failed run as a hard fault: after `fall` failures the VRRP instance enters **FAULT** and the VIP is removed. Adding a **non-zero weight** instead adds (or subtracts) from the instance priority on each success/failure, which lets the VIP stay put even when checks fail. See `vrrp_script` and `track_script` in `keepalived.conf(5)`.

All three scripts in the template use `interval 5`, `timeout 5`, `rise 2`, `fall 2` and `init_fail`:

- `rise`/`fall` default to `1`, so without them a single slow check moves a VIP. Two runs in a row must agree here — roughly 10 seconds to act.
- `timeout` defaults to `interval`. A run that takes longer is killed and **counted as a failure**, which is the wanted answer for a hung MySQL.
- `init_fail` marks the script failed until it has really passed once, so restarting keepalived cannot park the writer VIP on a replica for the first few seconds.

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

Similar in spirit to the legacy `ip_controller` flow: the VIP **remains** on the last node while checks fail, and alerting still fires. In `keepalived.conf.template`, swap each plain `track_script` line for its `weight -5` twin: comment out `chk_mysql_writer` and `chk_mysql_writer_or_reader`, then uncomment `chk_mysql_writer weight -5` and `chk_mysql_writer_or_reader weight -5`, so those scripts adjust priority instead of forcing FAULT. Leaving both lines in place does **not** work — keepalived logs `duplicate track_script ... - ignoring` and keeps the non-sticky behaviour.

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

Sticky mode is what `--priority-threshold` in the FIFO handler is for. A sticky node keeps the VIP at a *reduced* priority, so the metric must not report it as healthy. Keep `--priority-threshold` equal to `$KEEPALIVED_PRIORITY` — the template already wires it that way — and every sticky failure drops the effective priority below the threshold and reports `1`.

## Observability and alerting

Keepalived publishes VRRP state and priority changes to a FIFO (`vrrp_notify_fifo` in the template). [`notify_fifo_handler.sh`](notify_fifo_handler.sh) consumes the FIFO and writes one Prometheus textfile per VIP:

```
${PROM_OUTPUT_DIR}/keepalived_mysql_<vip>.prom
```

Default output directory: `/home/percona/pmm/collectors/textfile-collector/high-resolution` (override with `--prom-output-dir`). The PMM agent scrapes this directory like any other textfile collector target. Files are written to a temp name and renamed, so the collector never reads a half-written file.

Each file exposes two series:

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `percona_keepalived_mysql` | untyped | `cluster`, `vip`, `role` | `0` = node currently holds the VIP and is healthy for that role; `1` = node does not, or VIP is unhealthy |
| `percona_keepalived_mysql_last_report_ts` | untyped | same as above | Unix timestamp of the last FIFO event for this VIP |

VRRP states are mapped like this:

| FIFO state | Metric |
|------------|--------|
| `MASTER` | `0` — or `1` when the priority is below `--priority-threshold` |
| `MASTER_PRIORITY` (priority change while master) | same rule as `MASTER` |
| `MASTER_RX_LOWER_PRI` (master saw a lower-priority advert) | same rule as `MASTER` — the node still holds the VIP |
| `BACKUP`, `BACKUP_PRIORITY`, `FAULT`, `STOP`, `DELETED` | `1` |

### Notify-handler options

| Flag | Description | Default |
|------|-------------|---------|
| `--cluster NAME` | Cluster label applied to all metrics | required |
| `--writer-vip IP` | Writer VIP address (label and file name) | required |
| `--reader-vip IP` | Reader VIP address (label and file name) | required |
| `--writer-instance NAME` | `vrrp_instance` name of the writer VIP | `VI_MYSQL_WRITER` |
| `--reader-instance NAME` | `vrrp_instance` name of the reader VIP | `VI_MYSQL_READER` |
| `--priority-threshold N` | A `MASTER` state with an effective priority below this value is reported as unhealthy (`1`). Set it to the base `priority` of the `vrrp_instance` blocks. | `10` |
| `--prom-output-dir DIR` | Output directory for the `.prom` files | `/home/percona/pmm/collectors/textfile-collector/high-resolution` |
| `-h`, `--help` | Print the option list | — |

### Alert rule

[`keepalived-mysql-vip.alerts.yaml`](keepalived-mysql-vip.alerts.yaml) is a **PMM alert rule template** (root key `templates:`, which is what PMM validates on upload). It defines `Percona_MS_KeepalivedMySQLVIPUnhealthy`:

```text
min by (cluster, node_name) (percona_keepalived_mysql) == 1
```

It fires **per node**: a node whose writer and reader metrics are both `1` holds neither VIP. In a healthy two-node cluster each node holds one, so the minimum is `0` on both.

If you run plain Prometheus or VMAlert instead of PMM alerting, the same rule as a rules file is:

```yaml
groups:
  - name: keepalived-mysql-vip
    rules:
      - alert: Percona_MS_KeepalivedMySQLVIPUnhealthy
        expr: min by (cluster, node_name) (percona_keepalived_mysql) == 1
        for: 1m
        labels:
          severity: critical
```

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
| `/var/log/percona/.check_mysql_last_error.<mode>` | `check_mysql.sh` (stderr of the last `mysql` call for that mode) |
| `journalctl -u keepalived` | keepalived itself (state transitions, script timeouts, and the notify handler's stderr) |
| `${PROM_OUTPUT_DIR}/keepalived_mysql_<vip>.prom` | `notify_fifo_handler.sh` (metric snapshot) |

## Known limits

- **Metrics are event-driven.** A `.prom` file is rewritten only when keepalived reports a VRRP change. If keepalived stops, or the node is decommissioned, the last values stay on disk and keep looking healthy. Watch the keepalived unit itself (`systemctl status keepalived`) as well; `percona_keepalived_mysql_last_report_ts` gives you the age of the last event if you want to build a staleness check.
- **Writer election is not deterministic when both nodes are writable.** Both nodes carry the same base priority, so if the writer check passes on both — both `read_only=0`, neither replicating from the peer, which is already a split brain at the MySQL level — VRRP breaks the tie by the higher `unicast_src_ip`. Fix the MySQL side; raising one node's priority would break the reader VIP preference.
- **One replication channel only.** The reader check reads the first channel returned by `SHOW REPLICA STATUS`. Multi-source replicas are not supported.
- **`auth_pass` is 8 characters.** VRRP only uses the first eight characters of the shared secret; anything longer is silently cut.
- **`virtual_router_id` must be unique on the L2 segment.** Two clusters using 51/52 on the same network will fight over the VIPs.
- **`script_user root`.** The check needs to read a root-only MySQL option file, so the template runs scripts as root and relies on `enable_script_security`: `/`, `/etc`, `/etc/keepalived` and both scripts must be root-owned and not group- or world-writable, otherwise keepalived disables the scripts and the VIPs never move.

## Tests

Both scripts have offline tests — no MySQL, no keepalived, no root:

```bash
bash tests/run_offline_tests.sh
```

A fake `mysql` client answers the queries for MySQL 5.7, 8.0 and 8.4 field names, and a plain file stands in for the VRRP FIFO. The suite covers every writer/reader/fallback decision, the `no_vip` kill switch, bad options, and the VRRP state to metric mapping.

## Installation

See [INSTALL.md](INSTALL.md) for the step-by-step guide.
