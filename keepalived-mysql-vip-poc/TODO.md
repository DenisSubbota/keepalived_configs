# TODO
---
Where i am working
10.30.50.115
10.30.50.117

--- 

1. Problem that with the sticky VIPs based on priority - it's hard to have an alerting in place, as if we add weight to check script, even with failure, state of vrrp still Master, and as nothing chaged -> no handler that can update .prom file 

The idea is to rework the handelrs with notify_fifo 
global_defs {
    enable_script_security
    script_user root
    vrrp_notify_fifo /run/keepalived-vrrp.fifo root^%^
    vrrp_notify_fifo_script "/etc/keepalived/notify_fifo_handler.sh /run/keepalived-vrrp.fifo"
    vrrp_notify_priority_changes  true
}

Example of fifo file, 
[denis_test_env] percona@denis_mysql84rw: high-resolution $ sudo cat /run/keepalived-vrrp.fifo
INSTANCE "VI_MYSQL_WRITER" BACKUP 10
INSTANCE "VI_MYSQL_WRITER" BACKUP_PRIORITY 40
INSTANCE "VI_MYSQL_READER" BACKUP_PRIORITY 15
INSTANCE "VI_MYSQL_READER" BACKUP 15
INSTANCE "VI_MYSQL_WRITER" MASTER 40
INSTANCE "VI_MYSQL_READER" FAULT 15
INSTANCE "VI_MYSQL_WRITER" MASTER_PRIORITY 10
INSTANCE "VI_MYSQL_READER" BACKUP_PRIORITY 10
INSTANCE "VI_MYSQL_READER" BACKUP 10
INSTANCE "VI_MYSQL_WRITER" MASTER_PRIORITY 40
INSTANCE "VI_MYSQL_READER" BACKUP_PRIORITY 15

For script we can set nagative weights and afterward can compare with the bla bla 
There we can process based on `MASTER/MASTER_PRIORITY` labels and if anything is below set `threhsold`( it should be 10) it should update .prom file with failure

Also for not sticky VIP mode we can monitor `FAULT/BACKUP/BACKUP_PRIORITY` state and set it to falce as well

Writer instance fail when state of VI_MYSQL_WRITER: 
- FAULT 
- BACKUP
- BACKUP_PRIORITY
- MASTER below 10 
- MASTER_PRIORITY below 10
Writer instance OK when state of VI_MYSQL_WRITER: 
- MASTER = 10 
- MASTER_PRIORITY = 10

Reader instance fail when state of VI_MYSQL_READER: 
- FAULT 
- BACKUP
- BACKUP_PRIORITY
Reader instance fail when state of VI_MYSQL_READER: 
- MASTER 
- MASTER_PRIORITY 
---

3. Test and  sure that all scenarious covered 

4. Tidy up readme  + comments sections to have only reasonable info ( remove overwhelming information)
5. Push it on github 
6. Ask someone from GASteam/T2/Marco Tusa to review it and provide their vision


done on 24/03/26 
- 1. Current alert don't don't have node_name type of vip, vip , only have cluster for now - need to fix 
   The alert should be triggered based on simple logic - Healty cluster has next metrics role writer = one metric is 0 and second metrics is 1, while for role reader it should be more than one `0` avaialable (2+) also it should be matching by cluster only and it should be single alert - also all  labels available should be present in alert, nothing should be abbadoned
   DONE — per-node check: alert fires when writer=1 AND reader=1 on same {cluster, node_name} (node holds neither VIP).

Done 25/03/26 
With --allow-primary-as-replica - when read only = 0 on replica 
 Solutions:
   - primary with flag ^ -> show replica status -> [`Source_Host/Master_Host`] should not have ip of other keepalived instance, and it can be provided dynamically via KEEPALIVED_PEER_IP 
   - alternatively we may want just to add a CAUTION in to the README for the --allow-primary-as-repica flag and provide details on what could happen if both replica and primary becomes RO with replication running 
