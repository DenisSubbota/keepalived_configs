# TODO

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
