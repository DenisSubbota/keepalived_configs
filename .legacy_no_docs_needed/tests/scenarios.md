# Test scenarios (manual)

As this is a POC, test cases were applied on **MySQL 8.4** only.

## Topology (baseline)

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID]
+ 10.30.50.117:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID]
```

## Scenario: both nodes healthy (expected steady state)

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )
+ 10.30.50.117:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID] ( Reader_VIP: 192.168.88.19 )
```

## Scenario: disable `read_only` on replica → Reader VIP moves to primary

Action:

```bash
mysql -h 10.30.50.117 -e "set global read_only=0"
```

Result:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )( Reader_VIP: 192.168.88.19 )
+ 10.30.50.117:3306 [0s,ok,8.4.6-6,rw,ROW,>>,GTID]
```

Keepalived logs (replica instance):

```text
Nov 25 13:30:05 ubuntu Keepalived_vrrp[909470]: Script `chk_mysql_reader` now returning 1
Nov 25 13:30:05 ubuntu Keepalived_vrrp[909470]: VRRP_Script(chk_mysql_reader) failed (exited with status 1)
Nov 25 13:30:05 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 20 to 10
Nov 25 13:30:08 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Master received advert from 10.30.50.115 with higher priority 15, ours 10
Nov 25 13:30:08 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering BACKUP STATE
```

Return replica back to RO:

```bash
mysql -h 10.30.50.117 -e "set global read_only=1"
```

Keepalived logs (replica instance):

```text
Nov 25 13:32:55 ubuntu Keepalived_vrrp[909470]: Script `chk_mysql_reader` now returning 0
Nov 25 13:32:55 ubuntu Keepalived_vrrp[909470]: VRRP_Script(chk_mysql_reader) succeeded
Nov 25 13:32:55 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 10 to 20
Nov 25 13:32:55 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (15) advert from 10.30.50.115 - discarding
Nov 25 13:32:56 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (15) advert from 10.30.50.115 - discarding
Nov 25 13:32:57 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (15) advert from 10.30.50.115 - discarding
Nov 25 13:32:58 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering MASTER STATE
```

## Scenario: primary switches to RO → Writer VIP removed, Reader VIP stays on replica

Action:

```bash
mysql -h 10.30.50.115 -e "set global read_only=1"
```

Result:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,ro,ROW,>>,GTID]
+ 10.30.50.117:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID] ( Reader_VIP: 192.168.88.19 )
```

Keepalived logs (primary instance):

```text
Nov 25 13:35:08 ubuntu Keepalived_vrrp[504578]: Script `chk_mysql_writer` now returning 1
Nov 25 13:35:13 ubuntu Keepalived_vrrp[504578]: VRRP_Script(chk_mysql_writer) failed (exited with status 1)
Nov 25 13:35:13 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_WRITER) Entering FAULT STATE
```

Return primary back to RW:

```bash
mysql -h 10.30.50.115 -e "set global read_only=0"
```

Keepalived logs (primary instance):

```text
Nov 25 13:36:33 ubuntu Keepalived_vrrp[504578]: Script `chk_mysql_writer` now returning 0
Nov 25 13:36:38 ubuntu Keepalived_vrrp[504578]: VRRP_Script(chk_mysql_writer) succeeded
Nov 25 13:36:38 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_WRITER) Entering BACKUP STATE
Nov 25 13:36:38 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Changing effective priority from 10 to 15
Nov 25 13:36:42 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_WRITER) Entering MASTER STATE
```

Back to steady state:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )
+ 10.30.50.117:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID] ( Reader_VIP: 192.168.88.19 )
```

## Scenario: stop replica → Reader VIP falls back to primary

Action:

```bash
mysql -h 10.30.50.117 -e "stop replica"
```

Result:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )( Reader_VIP: 192.168.88.19 )
- 10.30.50.117:3306 [null,nonreplicating,8.4.6-6,ro,ROW,>>,GTID]
```

Keepalived logs (replica instance):

```text
Nov 25 13:32:58 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering MASTER STATE
Nov 25 14:14:50 ubuntu Keepalived_vrrp[909470]: Script `chk_mysql_reader` now returning 1
Nov 25 14:14:50 ubuntu Keepalived_vrrp[909470]: VRRP_Script(chk_mysql_reader) failed (exited with status 1)
Nov 25 14:14:50 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 20 to 10
Nov 25 14:14:53 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Master received advert from 10.30.50.115 with higher priority 15, ours 10
Nov 25 14:14:53 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering BACKUP STATE
```

Start replica again:

```bash
mysql -h 10.30.50.117 -e "start replica"
```

Keepalived logs (replica instance):

```text
Nov 25 14:16:15 ubuntu Keepalived_vrrp[909470]: Script `chk_mysql_reader` now returning 0
Nov 25 14:16:15 ubuntu Keepalived_vrrp[909470]: VRRP_Script(chk_mysql_reader) succeeded
Nov 25 14:16:15 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 10 to 20
Nov 25 14:16:15 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.115 - discarding
Nov 25 14:16:16 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.115 - discarding
Nov 25 14:16:17 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.115 - discarding
Nov 25 14:16:18 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering MASTER STATE
```

Back to steady state:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )
+ 10.30.50.117:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID] ( Reader_VIP: 192.168.88.19 )
```

## Scenario: replication lag exceeds threshold (example threshold: 12s)

Observation:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )( Reader_VIP: 192.168.88.19 )
+ 10.30.50.117:3306 [34s,ok,8.4.6-6,ro,ROW,>>,GTID]
```

Keepalived logs (replica):

```text
Nov 25 14:18:30 ubuntu Keepalived_vrrp[909470]: Script `chk_mysql_reader` now returning 1
Nov 25 14:18:30 ubuntu Keepalived_vrrp[909470]: VRRP_Script(chk_mysql_reader) failed (exited with status 1)
Nov 25 14:18:30 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 20 to 10
Nov 25 14:18:33 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Master received advert from 10.30.50.115 with higher priority 15, ours 10
Nov 25 14:18:33 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering BACKUP STATE
```

Keepalived logs (primary):

```text
Nov 25 14:16:18 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_WRITER) Entering BACKUP STATE
Nov 25 14:16:18 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Changing effective priority from 10 to 15
Nov 25 14:16:18 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Master received advert from 10.30.50.117 with higher priority 20, ours 15
Nov 25 14:16:18 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Entering BACKUP STATE
Nov 25 14:16:22 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_WRITER) Entering MASTER STATE
Nov 25 14:18:30 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.117 - discarding
Nov 25 14:18:31 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.117 - discarding
Nov 25 14:18:32 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.117 - discarding
Nov 25 14:18:33 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Entering MASTER STATE
```

Once lag resolved, VIPs moved back to the steady state.

## Scenario: failover with Orchestrator (`graceful-master-takeover`)

Before:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )
+ 10.30.50.117:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID] ( Reader_VIP: 192.168.88.19 )
```

Action:

```bash
orchestrator-client -c graceful-master-takeover -i 10.30.50.117
```

After failover (Writer VIP is not assigned because new primary has no replica under it):

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.117:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID]
- 10.30.50.115:3306 [null,nonreplicating,8.4.6-6,ro,ROW,>>,GTID,downtimed] ( Reader_VIP: 192.168.88.19 )
```

Logs (ex-primary `115`):

```text
Nov 25 14:20:28 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Master received advert from 10.30.50.117 with higher priority 20, ours 15
Nov 25 14:20:28 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Entering BACKUP STATE
Nov 25 14:22:25 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.117 - discarding
Nov 25 14:22:26 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.117 - discarding
Nov 25 14:22:27 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.117 - discarding
Nov 25 14:22:28 ubuntu Keepalived_vrrp[504578]: Script `chk_mysql_writer` now returning 1
Nov 25 14:22:28 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Entering MASTER STATE
Nov 25 14:22:33 ubuntu Keepalived_vrrp[504578]: VRRP_Script(chk_mysql_writer) failed (exited with status 1)
Nov 25 14:22:33 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_WRITER) Entering FAULT STATE
Nov 25 14:22:33 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Changing effective priority from 15 to 10
```

Logs (current primary `117`):

```text
Nov 25 14:20:25 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 10 to 20
Nov 25 14:20:25 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (15) advert from 10.30.50.115 - discarding
Nov 25 14:20:26 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (15) advert from 10.30.50.115 - discarding
Nov 25 14:20:27 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) received lower priority (15) advert from 10.30.50.115 - discarding
Nov 25 14:20:28 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering MASTER STATE
Nov 25 14:22:25 ubuntu Keepalived_vrrp[909470]: Script `chk_mysql_reader` now returning 1
Nov 25 14:22:25 ubuntu Keepalived_vrrp[909470]: VRRP_Script(chk_mysql_reader) failed (exited with status 1)
Nov 25 14:22:25 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 20 to 10
Nov 25 14:22:28 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Master received advert from 10.30.50.115 with higher priority 15, our>
Nov 25 14:22:28 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering BACKUP STATE
```

Start replication on ex-primary:

```bash
orchestrator-client -c start-replica -i 10.30.50.115
```

Return to steady state:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.117:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )
+ 10.30.50.115:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID] ( Reader_VIP: 192.168.88.19 )
```

Logs (after failover, primary `117`):

```text
Nov 25 14:22:25 ubuntu Keepalived_vrrp[909470]: Script `chk_mysql_reader` now returning 1
Nov 25 14:22:25 ubuntu Keepalived_vrrp[909470]: VRRP_Script(chk_mysql_reader) failed (exited with status 1)
Nov 25 14:22:25 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 20 to 10
Nov 25 14:22:28 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Master received advert from 10.30.50.115 with higher priority 15, ours 10
Nov 25 14:22:28 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Entering BACKUP STATE
Nov 25 14:25:20 ubuntu Keepalived_vrrp[909470]: Script `chk_mysql_writer` now returning 0
Nov 25 14:25:25 ubuntu Keepalived_vrrp[909470]: VRRP_Script(chk_mysql_writer) succeeded
Nov 25 14:25:25 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_WRITER) Entering BACKUP STATE
Nov 25 14:25:25 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_READER) Changing effective priority from 10 to 15
Nov 25 14:25:29 ubuntu Keepalived_vrrp[909470]: (VI_MYSQL_WRITER) Entering MASTER STATE
```

Logs (replica `115`):

```text
Nov 25 14:22:26 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.117 - discar>
Nov 25 14:22:27 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) received lower priority (10) advert from 10.30.50.117 - discar>
Nov 25 14:22:28 ubuntu Keepalived_vrrp[504578]: Script `chk_mysql_writer` now returning 1
Nov 25 14:22:28 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Entering MASTER STATE
Nov 25 14:22:33 ubuntu Keepalived_vrrp[504578]: VRRP_Script(chk_mysql_writer) failed (exited with status 1)
Nov 25 14:22:33 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_WRITER) Entering FAULT STATE
Nov 25 14:22:33 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Changing effective priority from 15 to 10
Nov 25 14:25:23 ubuntu Keepalived_vrrp[504578]: Script `chk_mysql_reader` now returning 0
Nov 25 14:25:23 ubuntu Keepalived_vrrp[504578]: VRRP_Script(chk_mysql_reader) succeeded
Nov 25 14:25:23 ubuntu Keepalived_vrrp[504578]: (VI_MYSQL_READER) Changing effective priority from 10 to 20
```

## Scenario: reset replica (no hosts under the primary) → Writer VIP removed, Reader VIP stays

Before:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.115
10.30.50.115:3306   [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Writer_VIP: 192.168.88.18 )
+ 10.30.50.117:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID] ( Reader_VIP: 192.168.88.19 )
```

Action:

```bash
mysql -h 10.30.50.117 -e " stop replica; reset replica all"
```

Reader VIP removed from replica:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.117
10.30.50.117:3306 [0s,ok,8.4.6-6,ro,ROW,>>,GTID]
```

Reader VIP moved to primary; writer considered unhealthy (no replicas attached) so Writer VIP removed:

```text
[denis_test_env] percona@monitor-gascan: ~ $ orchestrator-client -c topology -i 10.30.50.115
10.30.50.115:3306 [0s,ok,8.4.6-6,rw,ROW,>>,GTID] ( Reader_VIP: 192.168.88.19 )
```

