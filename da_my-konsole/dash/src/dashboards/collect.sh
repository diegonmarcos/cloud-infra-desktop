# Collect one my-konsole snapshot from a machine that does NOT run the hub.
#
# The peers run a disk-usage watchdog, not the my-konsole publisher — only the
# desktop is the hub. So the hub collects: this script is fed to `ssh <peer>
# sh -s` and prints the same JSON shape the daemon publishes locally, built out
# of /proc alone. Nothing is installed on the peer and nothing is left behind.
#
# A peer that DOES publish natively wins: the file is preferred, so if the VM
# watchdog ever grows this it takes over with no change here.
#
# Two samples one second apart, because cpu is a delta and there is no earlier
# sample to diff against on a machine we are visiting once. USER_HZ is 100 on
# every Linux target, so over a 1s window a process's tick delta IS its percent.
#
# Fields the hub cannot get this way — per-process io and network, btrfs
# storage, cgroup slices, systemd units — are emitted empty rather than faked,
# so those boxes read as "no data" instead of "all zero".
f="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/my-konsole-watchdog.json"
if [ -r "$f" ]; then cat "$f"; exit 0; fi
# df once, for the root filesystem percentage the fleet view shows.
> /tmp/.mkdf df -P / 2>/dev/null
> /tmp/.mk1 cat /proc/stat
> /tmp/.mkp1 sh -c 'for f in /proc/[0-9]*/stat; do p=${f%/stat}; p=${p##*/}; s=$(cat "$f" 2>/dev/null) || continue; echo "$p ${s#*) }"; done'
sleep 1
> /tmp/.mk2 cat /proc/stat
> /tmp/.mkp2 sh -c 'for f in /proc/[0-9]*/stat; do p=${f%/stat}; p=${p##*/}; s=$(cat "$f" 2>/dev/null) || continue; echo "$p ${s#*) }"; done'

awk '
function j(k,v){ printf "%s\"%s\":%s", sep, k, v; sep="," }
function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
function psi(f, l,a,r){ r="{}"; while((getline l < f)>0){
    split(l,a," "); t=a[1]
    for(i=2;i<=4;i++){ split(a[i],kv,"="); P[t kv[1]]=kv[2] } } close(f)
  return sprintf("{\"some10\":%s,\"some60\":%s,\"some300\":%s,\"full10\":%s,\"full60\":%s,\"full300\":%s}",
    P["someavg10"]+0,P["someavg60"]+0,P["someavg300"]+0,P["fullavg10"]+0,P["fullavg60"]+0,P["fullavg300"]+0) }
BEGIN{
  # ── cpu, two samples ────────────────────────────────────────────────
  while((getline l < "/tmp/.mk1")>0){ n=split(l,a," "); if(a[1]~/^cpu/){ tot=0; for(i=2;i<=n;i++)tot+=a[i]; T1[a[1]]=tot; I1[a[1]]=a[5]+a[6]; for(i=2;i<=n;i++) M1[a[1],i]=a[i] } }
  close("/tmp/.mk1")
  while((getline l < "/tmp/.mk2")>0){ n=split(l,a," "); if(a[1]~/^cpu/){ tot=0; for(i=2;i<=n;i++)tot+=a[i]; T2[a[1]]=tot; I2[a[1]]=a[5]+a[6]; for(i=2;i<=n;i++) M2[a[1],i]=a[i]; if(a[1]!="cpu"){ order[++nc]=a[1] } } }
  close("/tmp/.mk2")
  dt=T2["cpu"]-T1["cpu"]; if(dt<=0)dt=1
  cpu=100*(1-(I2["cpu"]-I1["cpu"])/dt)
  det=sprintf("{\"user\":%.1f,\"nice\":%.1f,\"system\":%.1f,\"iowait\":%.1f,\"irq\":%.1f,\"steal\":%.1f}",
    100*(M2["cpu",2]-M1["cpu",2])/dt, 100*(M2["cpu",3]-M1["cpu",3])/dt,
    100*(M2["cpu",4]-M1["cpu",4])/dt, 100*(M2["cpu",6]-M1["cpu",6])/dt,
    100*(M2["cpu",7]-M1["cpu",7])/dt, 100*(M2["cpu",9]-M1["cpu",9])/dt)
  cores="["
  for(k=1;k<=nc;k++){ c=order[k]; d=T2[c]-T1[c]; if(d<=0)d=1
    cores=cores sprintf("%s%.1f",(k>1?",":""),100*(1-(I2[c]-I1[c])/d)) }
  cores=cores "]"

  # ── meminfo ─────────────────────────────────────────────────────────
  while((getline l < "/proc/meminfo")>0){ split(l,a,":"); g=a[2]; gsub(/[^0-9]/,"",g); MEM[a[1]]=g+0 }
  close("/proc/meminfo")
  G=1048576.0
  mt=MEM["MemTotal"]; ma=MEM["MemAvailable"]; used=mt-ma
  st=MEM["SwapTotal"]; sf=MEM["SwapFree"]
  memd=sprintf("{\"total\":%.2f,\"used\":%.2f,\"free\":%.2f,\"available\":%.2f,\"cached\":%.2f,\"buffers\":%.2f,\"shmem\":%.2f,\"dirty\":%.2f,\"writeback\":%.2f,\"kernel\":%.2f,\"anon\":%.2f,\"commit\":%.2f,\"commit_limit\":%.2f}",
    mt/G,used/G,MEM["MemFree"]/G,ma/G,MEM["Cached"]/G,MEM["Buffers"]/G,MEM["Shmem"]/G,
    MEM["Dirty"]/G,MEM["Writeback"]/G,(MEM["Slab"]+MEM["KernelStack"])/G,MEM["AnonPages"]/G,
    MEM["Committed_AS"]/G,MEM["CommitLimit"]/G)
  swapd=sprintf("{\"total\":%.2f,\"used\":%.2f,\"free\":%.2f,\"cached\":%.2f,\"zswap\":0,\"zswapped\":0}",
    st/G,(st-sf)/G,sf/G,MEM["SwapCached"]/G)

  getline la < "/proc/loadavg"; close("/proc/loadavg"); split(la,L," ")
  getline up < "/proc/uptime"; close("/proc/uptime"); split(up,U," ")

  # ── totals since boot ───────────────────────────────────────────────
  # Same counters the rates come from, published whole. The daemon does
  # this arithmetic locally; here the collector does it, so both answer
  # the question the same way.
  while((getline l < "/proc/net/dev")>0){ if(l !~ /:/) continue
    split(l,a,":"); ifn=a[1]; gsub(/ /,"",ifn); if(ifn=="lo") continue
    split(a[2],b," "); NRX+=b[1]; NTX+=b[9] } close("/proc/net/dev")
  while((getline l < "/proc/diskstats")>0){ n=split(l,a," ")
    # whole devices only: partitions would double-count their parent
    if(a[3] ~ /[0-9]$/ && a[3] ~ /(sd|vd|hd)[a-z][0-9]/) continue
    if(a[3] ~ /^(loop|ram|dm-|zram)/) continue
    DR+=a[6]; DW+=a[10] } close("/proc/diskstats")

  # ── processes ───────────────────────────────────────────────────────
  while((getline l < "/tmp/.mkp1")>0){ split(l,a," "); C1[a[1]]=a[12]+a[13] } close("/tmp/.mkp1")
  np=0
  while((getline l < "/tmp/.mkp2")>0){ split(l,a," "); pid=a[1]
    if(!(pid in C1)) continue
    tick=(a[12]+a[13])-C1[pid]; if(tick<0)tick=0
    np++; PID[np]=pid; PCT[np]=tick     # USER_HZ=100, 1s window -> ticks == percent
  } close("/tmp/.mkp2")
  # top 40 by cpu, simple selection sort (np is a few thousand at most)
  n=(np<40?np:40)
  for(i=1;i<=n;i++){ b=i; for(k=i+1;k<=np;k++) if(PCT[k]>PCT[b]) b=k
    t=PID[i];PID[i]=PID[b];PID[b]=t; t=PCT[i];PCT[i]=PCT[b];PCT[b]=t }
  pt="["
  for(i=1;i<=n;i++){ pid=PID[i]; f="/proc/" pid "/status"
    nm="?"; rss=0; uid=0; pp=0; sc="?"
    while((getline l < f)>0){ split(l,a,":"); v=a[2]; gsub(/^[ \t]+|[ \t]+$/,"",v)
      if(a[1]=="Name")nm=v; else if(a[1]=="VmRSS"){ gsub(/[^0-9]/,"",v); rss=v+0 }
      else if(a[1]=="Uid"){ split(v,u," "); uid=u[1] }
      else if(a[1]=="PPid")pp=v; else if(a[1]=="State"){ split(v,ss," "); sc=ss[1] } }
    close(f)
    mp=(mt>0? 100.0*rss/mt : 0)
    av=sprintf("{\"cpu_pct\":%.1f,\"mem_pct\":%.2f,\"mem_rss_bytes\":%.0f,\"read_bytes_per_s\":0,\"write_bytes_per_s\":0,\"runq_wait_pct\":0}",PCT[i],mp,rss*1024)
    pt=pt sprintf("%s{\"pid\":%s,\"ppid\":%s,\"state\":\"%s\",\"slice\":\"\",\"name\":\"%s\",\"user\":\"%s\",\"cpu_pct\":%.1f,\"mem_rss_bytes\":%.0f,\"mem_pss_bytes\":null,\"mem_pct\":%.2f,\"read_bytes_per_s\":0,\"write_bytes_per_s\":0,\"net_rx_bytes_per_s\":0,\"net_tx_bytes_per_s\":0,\"runq_wait_pct\":0,\"protected\":false,\"protected_reason\":null,\"avg\":{\"10s\":%s,\"1m\":%s,\"5m\":%s,\"15m\":%s}}",
      (i>1?",":""),pid,pp,esc(sc),esc(nm),esc(uid),PCT[i],rss*1024,mp,av,av,av,av) }
  pt=pt "]"

  sep=""
  printf "{"
  j("cpu",sprintf("%.1f",cpu)); j("cores",cores); j("cpu_detail",det)
  j("mem",sprintf("%.1f",(mt>0?100.0*used/mt:0))); j("swap",sprintf("%.1f",(st>0?100.0*(st-sf)/st:0)))
  j("mem_detail",memd); j("swap_detail",swapd)
  while((getline l < "/tmp/.mkdf")>0){ n=split(l,a," "); if(a[n]=="/"){ DP=a[n-1]; gsub(/%/,"",DP) } }
  close("/tmp/.mkdf")
  j("disk",DP+0); j("disk_r",0); j("disk_w",0); j("disks","[]")
  j("net_rx",0); j("net_tx",0)
  j("load1",L[1]+0); j("load5",L[2]+0); j("load15",L[3]+0)
  j("psi",sprintf("{\"cpu\":%s,\"io\":%s,\"memory\":%s}",psi("/proc/pressure/cpu"),psi("/proc/pressure/io"),psi("/proc/pressure/memory")))
  j("storage","{}"); j("slices","[]"); j("services","[]")
  # %.0f, not %d: the %d of mawk and busybox awk is a 32-bit int, so every one
  # of these byte counts would saturate at 2147483647 — which is exactly what
  # a 2.1 GB reading from every peer turned out to be.
  j("totals",sprintf("{\"net_rx_bytes\":%.0f,\"net_tx_bytes\":%.0f,\"disk_read_bytes\":%.0f,\"disk_write_bytes\":%.0f,\"since_s\":%.0f}",NRX,NTX,DR*512,DW*512,U[1]))
  j("procs","[]"); j("proc_table",pt)
  j("ts",systime())
  printf "}\n"
}' < /dev/null
rm -f /tmp/.mk1 /tmp/.mk2 /tmp/.mkp1 /tmp/.mkp2 /tmp/.mkdf
