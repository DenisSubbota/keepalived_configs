# Keepalived MySQL VIP 

Two-node MySQL HA with separate writer and reader VIPs, health checks via `scripts/check_mysql.sh`, and PMM-friendly metrics from the FIFO notifier.

## Requirements
- Keepalived v2 on both nodes
- PMM agent installed (metrics flow described under **Alerting**)
- MySQL 5.7 through 8.4 supported, with a readable client config for the check user (e.g. `/home/percona/.my.cnf`)

### VRRP / firewall

No TCP/UDP: VRRP is **IP protocol 112** ([RFC 5798](https://www.rfc-editor.org/rfc/rfc5798)). Multicast mode uses **224.0.0.18**; this template uses **`unicast_peer`**, so allow **proto 112** both ways between the two node IPs (and **224.0.0.18** if you use multicast).

## Topology

```bash
                    ┌────────────────────────────────┐
                    │      PMM-server/Alerting       │
                    └───────┬────────────────┬───────┘
                            │                │
      ┌─────────────────────┘                └─────────────────────┐
      │               ┌──────────────────────────┐                 │          
      │               │        Application       │                 │         
      │               └─────┬──────────────┬─────┘                 │ 
      │                     │              │                       │ 
      │             ┌───────┘              └───────┐               │ 
      │             │ Write                  Read  │               │ 
      │  [db1]      ▼                              ▼        [db2]  │ 
      │  ┌───────────────────┐             ┌────────────────────┐  │
      │  │    Writer VIP     │◄───────────►│     Reader VIP     │  │
      │  │   [keepalived]    │    VRRP     │    [keepalived]    │  │
      │  ├───────────────────┤             ├────────────────────┤  │
      │  │    MySQL [rw]     │ Replication │     MySQL [ro]     │  │
      │  │  <Private IP 1>   ├────────────►│   <Private IP 2>   │  │
      │  ├───────────────────┤             ├────────────────────┤  │
      └─►│     pmm-agent     │             │     pmm-agent      │◄─┘
         └───────────────────┘             └────────────────────┘   
```

## Health checks (`check_mysql.sh`)

The script decides whether a node may hold the writer or reader VIP (exit `0` = healthy).

### Writer (`--primary`)

- `@@global.read_only = 0`
- Without `--allow-replica-except-from`: no replication channel configured
- With `--allow-replica-except-from PEER_IP`: replication is allowed **only** if `Source_Host` / `Master_Host` is **not** `PEER_IP` (so the peer replicating from its partner is never treated as the writer)

```bash
/etc/keepalived/check_mysql.sh --primary --allow-replica-except-from "${KEEPALIVED_PEER_IP}"
```

### Reader (`--replica`)

- `SHOW REPLICA STATUS` / `SHOW SLAVE STATUS` returns data
- `read_only = 1`
- IO and SQL threads `Yes`
- `Seconds_Behind_Source` / `Seconds_Behind_Master` strictly **less** than `KEEPALIVED_MAX_LAG_SECONDS`

```bash
/etc/keepalived/check_mysql.sh --replica --max-lag "${KEEPALIVED_MAX_LAG_SECONDS}"
```

### Writer-or-reader (`--writer-or-reader`)

Used so the reader VIP can land on the writer-capable node when the replica is unhealthy. The node passes if **either** the primary or replica check passes; pass the **same** extra flags you use for `--primary` and `--replica`.

```bash
/etc/keepalived/check_mysql.sh --writer-or-reader \
  --allow-replica-except-from "${KEEPALIVED_PEER_IP}" \
  --max-lag "${KEEPALIVED_MAX_LAG_SECONDS}"
```

## VIP behaviour

Keepalived `track_script` default **weight `0`**: repeated script failure puts the instance in **FAULT** (VIP dropped). A **non-zero** weight changes **priority** on success/failure instead (see `vrrp_script` / `track_script` in `keepalived.conf(5)`), which matches “sticky” behaviour.

### Non-sticky (recommended)

VIP should leave a node that is not healthy for that role.

- **`VI_MYSQL_WRITER`**: track only `chk_mysql_writer` with **no** weight (failure → FAULT).
- **`VI_MYSQL_READER`**: keep `chk_mysql_writer_or_reader` with **no** weight (failure → FAULT when neither writer nor reader role is healthy). Use weighted `chk_mysql_writer` / `chk_mysql_reader` as in the template to **prefer** a healthy replica over the writer for the reader VIP.

```bash
vrrp_instance VI_MYSQL_WRITER {
    # ...
    track_script {
        chk_mysql_writer
    }
}

vrrp_instance VI_MYSQL_READER {
    # ...
    track_script {
       chk_mysql_writer weight 5
       chk_mysql_reader weight 10
       chk_mysql_writer_or_reader
    }
}
```

### Sticky

Same idea as the legacy `ip_controller` flow: the VIP can **remain** on the last node while checks fail; alerting still fires. Enable the commented **`weight -5`** lines in `configs/keepalived.conf.fifo.template` for `chk_mysql_writer` (writer instance) and `chk_mysql_writer_or_reader` (reader instance) so those scripts adjust priority instead of using default weight `0` / FAULT.

```bash
vrrp_instance VI_MYSQL_WRITER {
    # ...
    track_script {
        chk_mysql_writer weight -5
    }
}

vrrp_instance VI_MYSQL_READER {
    # ...
    track_script {
       chk_mysql_writer weight 5
       chk_mysql_reader weight 10
       chk_mysql_writer_or_reader weight -5
    }
}
```

## Alerting

Keepalived writes VRRP state changes to a FIFO; `notify_fifo_handler.sh` turns that into a `.prom` file and the PMM agent scrapes it like any other textfile collector metrics.
