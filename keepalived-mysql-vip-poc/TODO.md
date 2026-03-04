# TODO
Figure out how to avoid unecessary `notify_fault` on the replica node where it's holding the Reader VIP
  Probably as workaround we can somehow check if `reader` vip assigned to the node, it should resolve `writer` prom on... hz don't like it  
  Better as we need to have a separate alert rule we can act like next 
 normal state [ prim 0,0 ], [ repl 1,0 ]
 crit  reader [ prim 0,0 ], [ repl 1,1 ]  
 crit  wr/rea [ prim 1,1 ], [ repl 1,1 ]

 So the alert expression should be combination where we expect for 
 healty writer: 
  1 writer Master (0), 1 writer failed (1)
 realty reader:
   2 readers in healty mode (0)
  We can compare based on the type=writer > 1, and for reader >0, so this can help us to workaround it 

Make sure that all scenarious covered 
Tidy up readme  + comments sections to have only reasonable info ( remove overwhelming information)
Push it on github 
Ask someone from GASteam/T2 to review 
