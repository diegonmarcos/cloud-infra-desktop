# System Protection — NixOS Desktop (Surface Pro 8: 8 cores, 8GB RAM)
#
# LOCAL (system.slice) — daemons started by systemd:
#   ├── kernel.slice        → NO CAP   — bare minimum for Linux to function
#   ├── os-essentials.slice → 95% cap  — protection + connectivity daemons
#   └── workload.slice      → 75% cap  — everything else (catch-all)
#
# REMOTE (user.slice) — login sessions:
#   ├── user-0.slice        → 90% cap  — root emergency
#   └── user-1000.slice     → 75% cap  — diego normal ops
#
# DESKTOP (machine.slice) — containers (Docker/Podman):
#   └── machine.slice       → 50% cap  — secondary workloads
#
# CPU guarantees (8 logical CPUs = 800% total):
#   kernel:        uncapped
#   os-essentials: 760% (95% of 800%)
#   workload:      600% (75% of 800%)
#   user-1000:     600% (75% of 800%)
#   user-0:        720% (90% of 800%)
#   machine:       400% (50% of 800%)
#
# VM equivalent: cloud/b_infra/_shared/vm-pilot/src/modules/protection/layer2-identity.nix
#
# ┌─────────────────────────┬──────────┬──────────┬──────────────┐
# │ Slice                   │ CPU      │ MemHigh  │ MemMax       │
# ├─────────────────────────┼──────────┼──────────┼──────────────┤
# │ kernel.slice            │ uncapped │ —        │ —            │
# │ os-essentials.slice     │ 760%/95% │ —        │ —            │
# │ connectivity.slice      │ weight   │ 200M min │ 200M min     │
# │ workload.slice          │ 600%/75% │ —        │ —            │
# │   └── nix-daemon        │ 200%     │ 1638M    │ 2048M  0swap │
# │ machine.slice           │ 400%/50% │ 2375M    │ 3031M  1024M │
# ├─────────────────────────┼──────────┼──────────┼──────────────┤
# │ user-1000 (diego)       │ 600%/75% │ 3112M    │ 4751M  2048M │
# │ user-0 (root)           │ 720%/90% │ 6963M    │ 7782M        │
# ├─────────────────────────┼──────────┼──────────┼──────────────┤
# │ sshd                    │ FIFO p1  │ 50M min  │ connectivity │
# │ rescue-ssh (dropbear)   │ FIFO p1  │ 20M min  │ connectivity │
# │ earlyoom                │ RR p1    │ —        │ (default)    │
# └─────────────────────────┴──────────┴──────────┴──────────────┘
#
{ config, pkgs, lib, ... }:

let
  # ── Data-driven freeze-proof policy ────────────────────────────────────
  # Single source of truth, ALSO read by build.sh (_apply_daemon_caps) so the
  # caps are enforced both at boot (here) and live before every build (engine).
  sysprot = builtins.fromJSON (builtins.readFile ./cloud-data-system-protection.json);

  # ── Hardware specs (Surface Pro 8) — DATA-DRIVEN (U1) ──────────────────
  # Converged onto the vm-pilot schema: cpu/ram_gb/rescue_port now live in
  # cloud-data-system-protection.json[.specs] / [.rescue_port], mirroring how
  # vm-pilot reads specs.ram_gb / specs.cpu / rescue_port from
  # _cloud-data-consolidated.json[._home_manager.vms.<vm>]. The desktop is not a
  # VM (absent from the cloud consolidated JSON), so its local data file is SoT.
  cpus = sysprot.specs.cpu;              # logical CPUs (4 cores × 2 threads)
  ramMB = sysprot.specs.ram_gb * 1024;   # 8GB RAM → 8192 MB
  rescuePort = sysprot.rescue_port;      # Dropbear rescue port (wg0-only)

  # ── Slice budgets (scaled by core count) ───────────────────────────────
  workloadCpuQuota = "${toString (cpus * 75)}%";     # 600%
  osEssentialsCpuQuota = "${toString (cpus * 95)}%";  # 760%
  userCpuQuota = "${toString (cpus * 75)}%";          # 600%
  rootCpuQuota = "${toString (cpus * 90)}%";          # 720%
  machineCpuQuota = "${toString (cpus * 50)}%";         # 400% (50% = 4/8 cores — fixes formula bug: was cpus*700/8=700%)
  machineCpuWeight = 50;                                # Docker loses to user desktop under CPU contention
  nixDaemonCpuQuota = "200%"; # 2 cores — nix eval is mostly single-threaded; bounded by parent workload.slice

  # ── Memory budgets ─────────────────────────────────────────────────────
  # BUG FIX (2026-06-27): user(85%)+machine(75%)=160% of RAM was the crash.
  # Both slices would simultaneously demand more than physical RAM → disk swap
  # thrash → CPU freeze. Fix: total MemoryMax fits in RAM; MemoryHigh gaps
  # give the kernel time to reclaim before the hard kill; swap caps prevent
  # disk I/O thrash on all slices.
  # BUG FIX (2026-07-02): userMemHigh=38%=3112M was BELOW the real desktop
  # working set (3× claude + qutebrowser + Plasma ≈ 3.5G). With MemorySwapMax=0
  # the slice sat pinned at memory.high (2.15M throttle events/boot) and the
  # kernel could only reclaim FILE-backed pages — evicting running executables
  # that immediately faulted back in through kcryptd/btrfs → sustained IO PSI
  # (full avg300=17), load 14, frozen desktop. Raise High above the working
  # set and allow a bounded swap valve (goes to zram prio 100, not disk).
  # Single source of truth: gui_session in cloud-data-system-protection.json
  # (build.sh reinforces the same values live before every Phase 1 build —
  # required because the old tight limits otherwise OOM-kill the very build
  # that would relax them: chicken-and-egg observed 3× on 2026-07-02).
  userMemMax = sysprot.gui_session.MemoryMax;         # 5734M ≈ 70% (was 58%=4751M)
  userMemHigh = sysprot.gui_session.MemoryHigh;       # 4505M ≈ 55% (was 38%=3112M — below working set = reclaim thrash)
  rootMemMax = "${toString (ramMB * 95 / 100)}M";     # 7782M
  rootMemHigh = "${toString (ramMB * 85 / 100)}M";    # 6963M
  machineMemMax = "${toString (ramMB * 37 / 100)}M";  # 3031M (was 75%=6144M — Docker can't eat 75% of RAM)
  machineMemHigh = "${toString (ramMB * 29 / 100)}M"; # 2375M (was absent — adds early reclaim trigger)
  machineMemSwapMax = "1024M";                         # (was absent — Docker disk swap was unlimited → thrash)
  nixMemMax = "${toString (ramMB * 25 / 100)}M";      # 2048M — OOM-kill before disk thrash (was 75%=6144M)
  nixMemHigh = "${toString (ramMB * 20 / 100)}M";     # 1638M — reclaim early (was 65%=5324M)
  # userMemMin: reduced from 38%=3113M. MemoryHigh+lower MemoryMax are the real
  # anti-freeze guards; the high MemoryMin was pinning 3GB unnecessarily.
  userMemMin = "${toString (ramMB * 12 / 100)}M";     # 983M (was 38%=3113M)
  nixMemSwapMax = "0";                                # NO disk swap — OOM-kill instead of I/O thrash freeze (was 2048M = THE BUG)
  # userMemSwapMax=0 also blocked ZRAM (per-cgroup swap cap can't distinguish
  # zram from disk), defeating the swappiness=150 zram-first design and leaving
  # the desktop with no pressure valve. 2048M lands on zram (prio 100 vs disk -1).
  userMemSwapMax = "2048M";                           # bounded valve → zram (was 0 = file-page thrash, 2026-07-02)
in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # KERNEL SYSCTL
  # ═══════════════════════════════════════════════════════════════════════════
  # Data-driven (cloud-data-system-protection.json → sysprot.sysctl): lower dirty
  # ratios flush writeback in small batches (no NVMe iowait burst), vfs_cache_pressure<100
  # keeps metadata cached, swappiness 150 prefers zram over the disk swapfile.
  boot.kernel.sysctl = sysprot.sysctl;

  # ═══════════════════════════════════════════════════════════════════════════
  # ZRAM: compressed swap in RAM (NixOS-only — HM can't write /etc/systemd/)
  # ═══════════════════════════════════════════════════════════════════════════
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;   # 100% of RAM, capped at 8GB
    memoryMax = 8 * 1024 * 1024 * 1024;  # 8GB max
    priority = 100;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # KERNEL WATCHDOG — last-line escape hatch (2026-07-10 v3)
  # ═══════════════════════════════════════════════════════════════════════════
  # The Surface exposes NO hardware watchdog (/sys/class/watchdog empty,
  # RuntimeWatchdogUSec=0) — before this, a true kernel wedge could ONLY be
  # cleared by holding the power button. softdog + systemd's RuntimeWatchdogSec
  # makes PID1 pet /dev/watchdog every runtime_sec/2; if the box is so wedged
  # PID1 can't run, softdog fires and reboots in runtime_sec. Session-on-disk
  # checkpoints bound the blast radius. Data-driven from sysprot.kernel_watchdog.
  boot.kernelModules = lib.optional sysprot.kernel_watchdog.enable sysprot.kernel_watchdog.module;
  systemd.watchdog.runtimeTime = lib.mkIf sysprot.kernel_watchdog.enable "${toString sysprot.kernel_watchdog.runtime_sec}s";

  # ═══════════════════════════════════════════════════════════════════════════
  # EARLYOOM: last resort OOM killer (RR scheduler)
  # ═══════════════════════════════════════════════════════════════════════════
  # earlyoom — DISABLED (2026-07-03 user directive: ONLY PSI-based killers, no
  # absolute-value triggers of any kind). earlyoom has no PSI awareness at all —
  # it is purely free-mem%/free-swap% — and repeatedly killed plasmashell on
  # transient MemAvailable dips while /proc/pressure/memory sat near 0 (reclaim
  # was keeping up fine, no real pressure). systemd-oomd (memory PSI, 50%) and
  # freeze-guard (mem/io/cpu PSI, 40/30/80) are the sole active killers now —
  # both genuinely PSI-gated. sysprot.earlyoom.enable is the single source of
  # truth; kept data-driven so it can be re-enabled without touching this file.
  services.earlyoom = {
    enable = sysprot.earlyoom.enable;
    freeMemThreshold = sysprot.earlyoom.free_mem;
    freeSwapThreshold = sysprot.earlyoom.free_swap;          # 100 = swap-gate removed → fire on mem alone
    freeMemKillThreshold = sysprot.earlyoom.free_mem_kill;
    freeSwapKillThreshold = sysprot.earlyoom.free_swap_kill; # 100 = swap-gate removed
    enableNotifications = true;
    reportInterval = 0;
    # Victim policy is DATA-DRIVEN (sysprot.earlyoom.prefer/avoid) — the
    # rationale and ordering contract live in cloud-data-system-protection.json.
    extraArgs = [
      "--prefer" sysprot.earlyoom.prefer
      "--avoid" sysprot.earlyoom.avoid
    ];
  };

  # Gated on earlyoom.enable: when earlyoom is DISABLED, services.earlyoom
  # produces no unit — but an UNCONDITIONAL serviceConfig override still forges
  # a phantom earlyoom.service with these settings and NO ExecStart, which
  # systemd refuses ("Service has no ExecStart=… Refusing"), failing activation
  # with exit 4 (2026-07-09: this aborted the switch before bootloader regen).
  # mkIf ties the hardening to the unit actually existing.
  systemd.services.earlyoom.serviceConfig = lib.mkIf sysprot.earlyoom.enable {
    Slice = "connectivity.slice";          # the untouchable island
    CPUSchedulingPolicy = "rr";
    CPUSchedulingPriority = 1;
    IOSchedulingClass = "realtime";        # always gets the NVMe queue
    IOSchedulingPriority = 0;
    OOMScoreAdjust = lib.mkForce (-1000);  # never killed
    OOMPolicy = "continue";
    MemoryMin = sysprot.reservation.memory_min;
    Nice = -20;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # IDENTITY TIER: root-watchdog (dedicated user, untouchable)
  # ═══════════════════════════════════════════════════════════════════════════
  # The user asked for identity-level separation above plain root. root-watchdog
  # is a dedicated SYSTEM user that owns the freeze-guard killer. It holds ONLY
  # the caps it needs (kill any process; read any /proc) — not full root — yet
  # sits in the untouchable island so it can ALWAYS act.
  # (root-sys-essentials is realized as the connectivity.slice ISLAND, not a
  # Linux user: dbus/NetworkManager/sddm/logind are hardwired to their own
  # identities and break if reassigned — the slice gives them the protection.)
  users.groups.root-watchdog = { };
  users.users.root-watchdog = {
    isSystemUser = true;
    group = "root-watchdog";
    description = "Freeze-guard watchdog identity — untouchable tier (kills runaways, never killed)";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # SYSTEMD-OOMD: PSI-aware proactive killer (layer 2, atop earlyoom)
  # ═══════════════════════════════════════════════════════════════════════════
  # Kills on sustained PSI memory pressure + high swap (zram) usage BEFORE the
  # kernel OOM does. enable*Slice sets ManagedOOMMemoryPressure=kill on the
  # standard slices (defaults: pressure 60% / swap 90%).
  systemd.oomd = {
    enable = sysprot.oomd.enable;
    enableRootSlice = true;
    enableSystemSlice = true;
    enableUserSlices = true;
    extraConfig = {
      DefaultMemoryPressureDurationSec = sysprot.oomd.duration;
      SwapUsedLimit = sysprot.oomd.SwapUsedLimit;
    };
  };

  # CRITICAL OVERRIDE: enable*Slice above sets ManagedOOMMemoryPressure=kill but with
  # an 80% default limit — ABOVE the 65% memory-pressure stall the freezes actually hit,
  # so it would never fire. Override the limit on every oomd-managed slice to the
  # evidence-based value (sysprot.oomd.pressure_limit = 50%). PSI is swap-independent,
  # so the 20G swap can no longer mask the stall.
  systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit = sysprot.oomd.pressure_limit;
  systemd.slices."system".sliceConfig.ManagedOOMMemoryPressureLimit = sysprot.oomd.pressure_limit;

  # ═══════════════════════════════════════════════════════════════════════════
  # FREEZE-GUARD: layer 3 — active PSI killer in the untouchable island
  # ═══════════════════════════════════════════════════════════════════════════
  # Runs as root-watchdog (CAP_KILL only). Every interval it reads
  # /proc/pressure/{memory,io}; if 'full avg10' (% of last 10s ALL tasks stalled)
  # exceeds the limit, it SIGKILLs the biggest hog (preferring compilers/browsers,
  # never an essential). RT CPU + realtime IO + OOMScoreAdjust=-1000 + reserved
  # RAM = it can always run, even when everything else is starved.
  systemd.services."freeze-guard" = lib.mkIf sysprot.watchdog.enabled {
    description = "Freeze-guard — PSI watchdog, kills runaways before the desktop locks up";
    wantedBy = [ "multi-user.target" ];
    after = [ "sysinit.target" ];
    path = with pkgs; [ coreutils procps gnugrep gawk ];
    serviceConfig = {
      User = "root-watchdog";
      Group = "root-watchdog";
      AmbientCapabilities = [ "CAP_KILL" "CAP_DAC_READ_SEARCH" ];
      CapabilityBoundingSet = [ "CAP_KILL" "CAP_DAC_READ_SEARCH" ];
      Slice = "connectivity.slice";
      Type = "simple";
      Restart = "always";
      RestartSec = 2;
      CPUSchedulingPolicy = "fifo";
      CPUSchedulingPriority = 1;
      IOSchedulingClass = "realtime";
      IOSchedulingPriority = 0;
      OOMScoreAdjust = -1000;
      MemoryMin = sysprot.reservation.memory_min;
      Nice = -20;
    };
    script = ''
      MEM_LIMIT=${toString sysprot.watchdog.mem_pressure_full_avg10}
      IO_LIMIT=${toString sysprot.watchdog.io_pressure_full_avg10}
      CPU_LIMIT=${toString sysprot.watchdog.cpu_pressure_some_avg10}
      MAX_KILLS=${toString sysprot.watchdog.max_kills_per_tick}
      INTERVAL=${toString sysprot.watchdog.interval_sec}
      PREFER="${lib.concatStringsSep "|" sysprot.watchdog.prefer_kill}"
      AVOID="${sysprot.watchdog.avoid_kill}"
      # ── memory.high-THRASH voter (v3, 2026-07-10) ──────────────────────────
      # The 13:06 freeze was INVISIBLE to PSI (memory.pressure ~35%, below every
      # limit) yet user-1000.slice hit memory.high 1.14M times reclaim-thrashing.
      # This voter watches the memory.events 'high' counter delta on the throttled
      # slice directly; sustained > HIGH_MAX/s for THRASH_SUSTAIN s → SIGKILL the
      # biggest-RSS process INSIDE that slice (cgroup.procs), never systemwide.
      THRASH_CG="/sys/fs/cgroup/${sysprot.watchdog.thrash_slice}"
      HIGH_MAX=${toString sysprot.watchdog.high_events_per_sec_max}
      THRASH_SUSTAIN=${toString sysprot.watchdog.thrash_sustain_sec}
      # ── per-slice PSI voter (v3.1, 2026-07-10) — the 15:29 freeze root cause ──
      # freeze-guard read GLOBAL /proc/pressure/io (=0.14%) and stayed blind while
      # the DESKTOP slice's own io.pressure was 96%/56% (IO-starved by a bulk
      # writer). A freeze is per-slice; watch the desktop slice's OWN pressure.
      WATCH_CG="/sys/fs/cgroup/${sysprot.watchdog.watch_slice}"
      SLICE_IO_LIMIT=${toString sysprot.watchdog.slice_io_full_avg10}
      SLICE_MEM_LIMIT=${toString sysprot.watchdog.slice_mem_full_avg10}
      HOG_CGS="${lib.concatStringsSep " " (map (s: "/sys/fs/cgroup/" + s) sysprot.watchdog.hog_slices)}"
      KTHREAD_RE="${sysprot.watchdog.kthread_comm_re}"
      # ── write-storm voter (v3.2) — the LEADING indicator PSI misses ─────────
      WS_MBPS=${toString sysprot.watchdog.write_storm_mb_per_sec}
      WS_DIRTY_MB=${toString sysprot.watchdog.dirty_mb_max}
      WS_SUSTAIN=${toString sysprot.watchdog.write_storm_sustain_sec}
      WS_DISK="${sysprot.watchdog.write_storm_disk}"

      # Disk write rate (MB/s) since the last call: field 10 of /proc/diskstats
      # (sectors written) * 512, delta / interval. Global writeback view — the
      # burst that fills dirty page cache before any PSI stall registers.
      disk_write_mbps() {
        local now sec
        sec=$(awk -v d="$WS_DISK" '$3==d {print $10; exit}' /proc/diskstats 2>/dev/null)
        sec=''${sec:-0}
        now=$sec
        if [ -n "$PREV_WSEC" ]; then
          echo $(( (now - PREV_WSEC) * 512 / 1024 / 1024 / (INTERVAL>0?INTERVAL:1) ))
        else echo 0; fi
        PREV_WSEC=$now
      }
      # Dirty + Writeback pages (MB) — the backlog that triggers synchronous
      # forced writeback (the stall) once it crosses vm.dirty_ratio.
      dirty_mb() {
        awk '/^Dirty:/{d=$2} /^Writeback:/{w=$2} END{print int((d+w)/1024)}' /proc/meminfo 2>/dev/null
      }
      # Top disk WRITER by /proc/PID/io write_bytes DELTA (bytes written since
      # last tick). Persistent map PREV_WB[pid]. Skips kthreads + avoid_kill.
      # Prints "pid mbdelta comm".
      pick_top_writer() {
        local p wb comm best_pid="" best_d=-1 best_comm="" d
        for p in /proc/[0-9]*; do
          p=''${p#/proc/}
          [ "$p" -gt 1 ] 2>/dev/null || continue
          wb=$(awk '/^write_bytes:/{print $2}' "/proc/$p/io" 2>/dev/null) || continue
          [ -n "$wb" ] || continue
          d=$(( wb - ''${PREV_WB[$p]:-$wb} ))
          PREV_WB[$p]=$wb
          [ "$d" -gt "$best_d" ] || continue
          is_kthread "$p" && continue
          comm=$(cat "/proc/$p/comm" 2>/dev/null) || continue
          echo "$comm" | grep -Eq -- "$AVOID" && continue
          best_d=$d; best_pid=$p; best_comm=$comm
        done
        [ -n "$best_pid" ] && echo "$best_pid $((best_d/1024/1024)) $best_comm"
      }

      # $2 = "full" (mem/io: all tasks stalled) or "some" (cpu: any task stalled).
      psi_avg10() {
        awk -v k="$2" '$1 == k { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { sub(/avg10=/,"",$i); print $i } }' "/proc/pressure/$1" 2>/dev/null
      }

      # Per-slice PSI: read a cgroup's OWN {io,memory,cpu}.pressure file.
      # $1 = cgroup dir, $2 = io|memory|cpu, $3 = full|some.
      psi_slice_avg10() {
        awk -v k="$3" '$1 == k { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { sub(/avg10=/,"",$i); print $i } }' "$1/$2.pressure" 2>/dev/null
      }

      # A pid is a kernel thread (never killable, never a valid victim) if its
      # comm matches KTHREAD_RE or it has zero RSS. The 15:29 guard wasted ticks
      # SIGKILLing kworker/thermald while the real IO hog kept running.
      is_kthread() {
        local c r
        c=$(cat "/proc/$1/comm" 2>/dev/null) || return 0
        echo "$c" | grep -Eq -- "$KTHREAD_RE" && return 0
        r=$(awk '/^VmRSS:/ {print $2}' "/proc/$1/status" 2>/dev/null)
        [ -z "$r" ] || [ "$r" -eq 0 ] 2>/dev/null
      }

      # Largest-RSS non-kthread, non-avoid victim across the HOG slices (the bulk
      # writers/CPU hogs that starve the desktop). Used when the DESKTOP slice is
      # starved but global PSI is low — the culprit is elsewhere, not the desktop.
      pick_hog_victim() {
        local cg p comm rss best_pid="" best_rss=-1 best_comm=""
        for cg in $HOG_CGS; do
          [ -r "$cg/cgroup.procs" ] || continue
          while read -r p; do
            [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || continue
            is_kthread "$p" && continue
            comm=$(cat "/proc/$p/comm" 2>/dev/null) || continue
            echo "$comm" | grep -Eq -- "$AVOID" && continue
            rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null)
            [ -n "$rss" ] || continue
            if [ "$rss" -gt "$best_rss" ]; then best_rss="$rss"; best_pid="$p"; best_comm="$comm"; fi
          done < "$cg/cgroup.procs"
        done
        [ -n "$best_pid" ] && echo "$best_pid $best_rss $best_comm"
      }

      # Pick the top offender by $1 sort key (rss or pcpu), skipping already-killed
      # pids ($2 = space-separated exclusion list). prefer_kill first, then any
      # non-avoid_kill process. Prints "pid metric comm".
      pick_victim() {
        local key="$1" skip="$2" excl=""
        [ -n "$skip" ] && excl="^($(echo "$skip" | tr ' ' '|')) "
        # `ps comm=` renders kernel threads with their kworker/ksoftirqd/... name;
        # KTHREAD_RE strips them so the guard never wastes a kill on an unkillable
        # kernel thread (the 15:29 kworker/thermald flailing). AVOID protects the
        # compositor/session essentials.
        local cmd="ps -eo pid=,$key=,comm= --sort=-$key"
        local line
        line=$($cmd | grep -E -- "$PREFER" | grep -E -v -- "$AVOID" | grep -E -v -- "$KTHREAD_RE" | { [ -n "$excl" ] && grep -E -v -- "$excl" || cat; } | head -n1)
        [ -z "$line" ] && line=$($cmd | grep -E -v -- "$AVOID" | grep -E -v -- "$KTHREAD_RE" | { [ -n "$excl" ] && grep -E -v -- "$excl" || cat; } | head -n1)
        echo "$line"
      }

      # Largest-RSS pid INSIDE the throttled cgroup (thrash voter target). Reads
      # the slice's own cgroup.procs — so the runaway that is actually filling
      # user-1000.slice is killed, never an innocent process elsewhere. Skips
      # avoid_kill comms (compositor/session infra). Prints "pid rss comm".
      pick_cgroup_victim() {
        local procs="$1/cgroup.procs" p comm rss best_pid="" best_rss=-1 best_comm=""
        [ -r "$procs" ] || return 1
        while read -r p; do
          [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || continue
          comm=$(cat "/proc/$p/comm" 2>/dev/null) || continue
          echo "$comm" | grep -Eq -- "$AVOID" && continue
          rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null)
          [ -n "$rss" ] || continue
          if [ "$rss" -gt "$best_rss" ]; then best_rss="$rss"; best_pid="$p"; best_comm="$comm"; fi
        done < "$procs"
        [ -n "$best_pid" ] && echo "$best_pid $best_rss $best_comm"
      }

      # Signal picker WITH ESCALATION (2026-07-10 v3 — root cause of the 13:06
      # freeze). Graceful SIGTERM for node/claude so Claude Code can print its
      # "claude --resume" hint; hard SIGKILL for everything else. CRITICAL FIX:
      # a graceful SIGTERM that is IGNORED must ESCALATE. The 13:06 freeze was
      # freeze-guard SIGTERM-ing the SAME claude pid (89831, comm=ld-linux) 20+
      # times over 75s while it sat wedged in IO-stall (D-state) and never died
      # — polite-forever with no teeth. Now: first offense = SIGTERM; if the
      # SAME pid is still the offender on a later tick (already in TERMED) =
      # SIGKILL. So a process that won't leave on request gets forced out within
      # one interval. Match on FULL CMDLINE (claude runs via ld-linux, comm
      # misses it). TERMED is a persistent cross-tick map (declared before the
      # loop); dead pids are pruned there.
      # Sets the global SIG (never echoes) and MUST be called directly, NOT via
      # $(do_kill ...): command substitution runs in a subshell, so a TERMED[]
      # mutation there would be lost and escalation would silently never fire
      # (caught in testing 2026-07-10). Callers do:  do_kill "$pid" "$name"; sig=$SIG
      do_kill() {
        local cmdline
        cmdline=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || echo "$2")
        case "$cmdline" in
          *claude*|*node*)
            if [ -n "''${TERMED[$1]:-}" ]; then
              kill -9 "$1" 2>/dev/null || true; unset "TERMED[$1]"; SIG=KILL-ESC
            else
              kill -TERM "$1" 2>/dev/null || true; TERMED[$1]=1; SIG=TERM
            fi ;;
          *) kill -9 "$1" 2>/dev/null || true; SIG=KILL ;;
        esac
      }

      # PSI IS THE ONLY KILL METRIC. No absolute CPU%/RSS/mem% triggers — those
      # cause false kills (Claude died at PSI=0). We act ONLY on real kernel stall
      # (PSI 'some'/'full' avg10 over limit); the victim is then RANKED by %cpu
      # (cpu breach) or RSS (mem/io breach) — ranking is victim-selection, not the
      # trigger. Graceful SIGTERM for node/claude via do_kill.
      echo "[freeze-guard] online as $(id -un); PSI trigger — cpuPSI(some)>$CPU_LIMIT | memPSI(full)>$MEM_LIMIT | ioPSI(full)>$IO_LIMIT; THRASH trigger — memory.high >$HIGH_MAX/s for ''${THRASH_SUSTAIN}s on $THRASH_CG; max $MAX_KILLS kills/tick"
      prev_high=""; thrash_secs=0; ws_secs=0; PREV_WSEC=""
      declare -A TERMED    # pids already SIGTERM'd once — escalate to SIGKILL on recurrence
      declare -A PREV_WB   # per-pid write_bytes for the write-storm voter's delta
      while :; do
        # Prune maps: drop pids that already died (unbounded-growth guard).
        for _p in "''${!TERMED[@]}"; do [ -d "/proc/$_p" ] || unset "TERMED[$_p]"; done
        for _p in "''${!PREV_WB[@]}"; do [ -d "/proc/$_p" ] || unset "PREV_WB[$_p]"; done

        cpu=$(psi_avg10 cpu some);    cpu=''${cpu:-0}
        mem=$(psi_avg10 memory full); mem=''${mem:-0}
        io=$(psi_avg10 io full);      io=''${io:-0}

        # ── VOTER: write-storm (v3.2) — LEADING indicator PSI misses ──────────
        # A write burst fills dirty page cache instantly (no stall → PSI flat);
        # the freeze hits later when dirty pages force synchronous writeback.
        # Watch the write RATE + dirty backlog directly and kill the top writer
        # BEFORE the stall. do_kill/pick_top_writer skip kthreads + essentials.
        wmbps=$(disk_write_mbps)
        dmb=$(dirty_mb); dmb=''${dmb:-0}
        if [ "$wmbps" -gt "$WS_MBPS" ] || [ "$dmb" -gt "$WS_DIRTY_MB" ]; then
          ws_secs=$(( ws_secs + INTERVAL ))
          echo "[freeze-guard] WRITE-STORM ''${wmbps}MB/s (>$WS_MBPS) dirty=''${dmb}MB (>$WS_DIRTY_MB) sustained ''${ws_secs}s/''${WS_SUSTAIN}s"
          if [ "$ws_secs" -ge "$WS_SUSTAIN" ]; then
            set -- $(pick_top_writer)
            wpid="$1"; wmb="$2"; wcomm="$3"
            if [ -n "$wpid" ] && [ "$wpid" -gt 1 ] 2>/dev/null; then
              do_kill "$wpid" "$wcomm"; wsig=$SIG
              echo "[freeze-guard] WRITE-STORM-KILL → SIG$wsig top-writer pid=$wpid ''${wmb}MB/tick ($wcomm)"
            else
              echo "[freeze-guard] WRITE-STORM: no eligible writer (all essential/kthread?)"
            fi
            ws_secs=0
          fi
        else
          ws_secs=0
        fi

        # ── VOTER: per-slice desktop starvation (v3.1) — the 15:29 root cause ──
        # The desktop froze with user.slice io.pressure=96%/56% while GLOBAL io
        # was 0.14% — a bulk writer was hogging the NVMe queue and starving the
        # compositor. The global voter below is blind to this. Read the DESKTOP
        # slice's OWN pressure; if IT is starved, the culprit is a hog ELSEWHERE
        # (workload/machine/system) — kill the biggest hog, never the desktop's
        # own stalled procs. EVERY evaluation over threshold logs.
        sio=$(psi_slice_avg10 "$WATCH_CG" io full);     sio=''${sio:-0}
        smem=$(psi_slice_avg10 "$WATCH_CG" memory full); smem=''${smem:-0}
        if awk "BEGIN { exit !($sio+0 > $SLICE_IO_LIMIT || $smem+0 > $SLICE_MEM_LIMIT) }"; then
          set -- $(pick_hog_victim)
          hpid="$1"; hrss="$2"; hcomm="$3"
          if [ -n "$hpid" ] && [ "$hpid" -gt 1 ] 2>/dev/null; then
            do_kill "$hpid" "$hcomm"; hsig=$SIG
            echo "[freeze-guard] DESKTOP-STARVED sliceIO=$sio sliceMEM=$smem (global io=$io) → SIG$hsig hog pid=$hpid rss=''${hrss}kB ($hcomm)"
          else
            echo "[freeze-guard] DESKTOP-STARVED sliceIO=$sio sliceMEM=$smem — no hog victim outside the desktop (all essential/kthread?)"
          fi
        fi

        # ── VOTER: memory.high thrash (PSI-invisible reclaim storm) ──────────
        # Watches the throttle counter itself, so it fires even when PSI stays
        # low (the exact 13:06 blind spot). EVERY evaluation logs (silence was
        # what made the last freeze undebuggable).
        cur_high=$(awk '$1=="high"{print $2}' "$THRASH_CG/memory.events" 2>/dev/null)
        cur_high=''${cur_high:-0}
        if [ -n "$prev_high" ]; then
          rate=$(( (cur_high - prev_high) / (INTERVAL > 0 ? INTERVAL : 1) ))
          [ "$rate" -lt 0 ] && rate=0
          if [ "$rate" -gt "$HIGH_MAX" ]; then
            thrash_secs=$(( thrash_secs + INTERVAL ))
            echo "[freeze-guard] THRASH-WATCH memory.high rate=''${rate}/s > $HIGH_MAX (sustained ''${thrash_secs}s/''${THRASH_SUSTAIN}s) on $THRASH_CG"
            if [ "$thrash_secs" -ge "$THRASH_SUSTAIN" ]; then
              set -- $(pick_cgroup_victim "$THRASH_CG")
              vpid="$1"; vrss="$2"; vcomm="$3"
              if [ -n "$vpid" ] && [ "$vpid" -gt 1 ] 2>/dev/null; then
                do_kill "$vpid" "$vcomm"; vsig=$SIG
                echo "[freeze-guard] THRASH-KILL memory.high ''${rate}/s → SIG$vsig pid=$vpid rss=''${vrss}kB ($vcomm) in $THRASH_CG"
              else
                echo "[freeze-guard] THRASH-KILL: no eligible victim in $THRASH_CG (all avoid_kill?) — cannot act"
              fi
              thrash_secs=0
            fi
          else
            thrash_secs=0
          fi
        fi
        prev_high="$cur_high"

        killed=""; n=0
        while [ "$n" -lt "$MAX_KILLS" ] && \
              awk "BEGIN { exit !($cpu+0 > $CPU_LIMIT || $mem+0 > $MEM_LIMIT || $io+0 > $IO_LIMIT) }"; do
          # Rank by %cpu when CPU is the breaching signal, else by RSS.
          if awk "BEGIN { exit !($cpu+0 > $CPU_LIMIT) }"; then key="pcpu"; else key="rss"; fi
          set -- $(pick_victim "$key" "$killed")
          pid="$1"; metric="$2"; name="$3"
          [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
          do_kill "$pid" "$name"; sig=$SIG
          echo "[freeze-guard] FREEZE-RISK cpuPSI=$cpu memPSI=$mem ioPSI=$io → SIG$sig pid=$pid rank-by=$key metric=$metric ($name)"
          killed="$killed $pid"; n=$((n + 1))
          sleep 0.3   # let PSI reflect the kill before re-reading
          cpu=$(psi_avg10 cpu some);    cpu=''${cpu:-0}
          mem=$(psi_avg10 memory full); mem=''${mem:-0}
          io=$(psi_avg10 io full);      io=''${io:-0}
        done
        [ "$n" -ge "$MAX_KILLS" ] && echo "[freeze-guard] hit max_kills_per_tick=$MAX_KILLS (cpuPSI=$cpu memPSI=$mem ioPSI=$io) — backing off one interval"
        sleep "$INTERVAL"
      done
    '';
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # FREEZE-GUARD SELF-CHECK: re-arms the PSI killer if manually stopped
  # ═══════════════════════════════════════════════════════════════════════════
  # 2026-07-04 incident: freeze-guard was manually `systemctl stop`ped during
  # debugging and stayed stopped for 3h22m through many `nixos-rebuild switch`
  # runs — switch-to-configuration only starts/restarts units whose definition
  # CHANGED; a manually-stopped-but-unchanged enabled unit is left exactly as
  # it is. The desktop then froze with PSI well past freeze-guard's own
  # trigger thresholds (cpuPSI=85%, memPSI=44%) with no killer running at all.
  # This timer closes that gap independent of whether a switch ever runs.
  systemd.timers."freeze-guard-selfcheck" = lib.mkIf sysprot.watchdog_selfcheck.enabled {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "${toString sysprot.watchdog_selfcheck.interval_sec}s";
    };
  };

  systemd.services."freeze-guard-selfcheck" = lib.mkIf sysprot.watchdog_selfcheck.enabled {
    serviceConfig.Type = "oneshot";
    path = with pkgs; [ systemd ];
    script = ''
      if ! systemctl is-active --quiet freeze-guard.service; then
        echo "[freeze-guard-selfcheck] freeze-guard.service is NOT active — re-arming"
        systemctl start freeze-guard.service
      fi
    '';
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # LOCAL TIER: SYSTEM SLICES (3-tier hierarchy)
  # ═══════════════════════════════════════════════════════════════════════════

  # kernel.slice — uncapped, Linux essentials
  systemd.slices."kernel" = {
    description = "Kernel-essential services — no cap";
  };

  # os-essentials.slice — 95% cap, protection + connectivity
  # v3 (2026-07-10): + MemoryMin so reclaim can NEVER evict sshd/session/logind
  # pages (the infra you need to debug a freeze), + high IOWeight so those
  # daemons keep the NVMe queue when workload bulk-writers storm it.
  systemd.slices."os-essentials" = {
    description = "OS-essential services — protection, connectivity";
    sliceConfig = {
      CPUQuota = osEssentialsCpuQuota;
      MemoryMin = sysprot.slice_protection.os_essentials_memory_min;
      IOWeight = sysprot.slice_protection.os_essentials_io_weight;
    };
  };

  # connectivity.slice — THE UNTOUCHABLE ISLAND (root-sys-essentials tier).
  # Hosts the killers (freeze-guard, earlyoom) + the mesh (sshd, rescue-ssh).
  # Guaranteed RAM (MemoryMin/Low), top CPU weight, top IO weight — so it can
  # ALWAYS run and ALWAYS kill whatever overwhelms the rest of the box.
  systemd.slices."connectivity" = {
    description = "UNTOUCHABLE island — killers (freeze-guard, earlyoom) + mesh (SSH, Dropbear)";
    sliceConfig = {
      MemoryMin = sysprot.reservation.memory_min;
      MemoryLow = sysprot.reservation.memory_min;
      CPUWeight = sysprot.reservation.cpu_weight;
      IOWeight = sysprot.reservation.io_weight;
    };
  };

  # workload.slice — 75% cap, catch-all for non-essential services
  # v3 (2026-07-10): + low IOWeight so bulk writers (docker/nix-daemon/backups)
  # yield the NVMe queue to the desktop + island — they can no longer IO-starve
  # the compositor the way the 13:06 reclaim thrash did.
  systemd.slices."workload" = {
    description = "Workload services — docker, containers, nix-daemon";
    sliceConfig = {
      CPUQuota = workloadCpuQuota;
      IOWeight = sysprot.slice_protection.workload_io_weight;
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # REMOTE TIER: USER SLICES (login sessions)
  # ═══════════════════════════════════════════════════════════════════════════

  # user-1000 (diego) — normal operations
  systemd.slices."user-1000" = {
    description = "User diego (UID 1000) resource limits";
    sliceConfig = {
      CPUQuota = userCpuQuota;
      MemoryHigh = userMemHigh;
      MemoryMax = userMemMax;
      MemoryMin = sysprot.gui_session.MemoryMin;   # reserved RAM — never reclaimed for a build (anti-freeze)
      IOWeight = 500;           # desktop I/O strongly preempts background/build I/O
    };
  };

  # user-0 (root) — emergency maintenance
  systemd.slices."user-0" = {
    description = "Root (UID 0) resource limits — emergency";
    sliceConfig = {
      CPUQuota = rootCpuQuota;
      MemoryHigh = rootMemHigh;
      MemoryMax = rootMemMax;
      IOWeight = 200;
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # DESKTOP TIER: machine.slice (containers)
  # ═══════════════════════════════════════════════════════════════════════════

  # user.slice — top-level user slice beats Docker/containers under CPU contention.
  # Also carries the oomd PSI-kill limit override (the desktop session is where the
  # observed 65% memory-pressure freeze lived — oomd kills the worst app at 50%).
  systemd.slices."user" = {
    sliceConfig = {
      CPUWeight = 200;  # user sessions (KDE + apps) 4× priority over Docker at root level
      ManagedOOMMemoryPressureLimit = sysprot.oomd.pressure_limit;  # override oomd's 80% default → 50%
    };
  };

  systemd.slices."machine" = {
    description = "Container workloads — Docker/Podman";
    sliceConfig = {
      MemoryMax = machineMemMax;
      MemoryHigh = machineMemHigh;
      CPUQuota = machineCpuQuota;
      CPUWeight = machineCpuWeight;
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # SERVICE ASSIGNMENTS: FIFO / RR / slice placement
  # ═══════════════════════════════════════════════════════════════════════════

  # sshd — FIFO lane 1, connectivity.slice
  systemd.services.sshd.serviceConfig = {
    Slice = "connectivity.slice";
    CPUSchedulingPolicy = "fifo";
    CPUSchedulingPriority = 1;
    IOSchedulingClass = "realtime";
    IOSchedulingPriority = 0;
    OOMScoreAdjust = lib.mkForce (-1000);
    OOMPolicy = "continue";
    MemoryMin = "50M";
    Nice = -20;
  };

  # nix-daemon — workload.slice, capped (THE build worker; cc1plus/rustc are its
  # cgroup children, so this caps the whole build subtree). Values from JSON;
  # build.sh re-applies them LIVE before every build (switch alone doesn't re-cap
  # the already-running daemon → the drift that froze the box 10×).
  systemd.services.nix-daemon.serviceConfig = {
    Slice = "workload.slice";
    MemoryMax = sysprot.nix_daemon.MemoryMax;
    MemoryHigh = sysprot.nix_daemon.MemoryHigh;
    MemorySwapMax = sysprot.nix_daemon.MemorySwapMax;  # "0" = NO swap → OOM-kill a build job instead of disk-thrash freeze
    CPUQuota = sysprot.nix_daemon.CPUQuota;
    OOMScoreAdjust = 250;
    IOWeight = 20;                  # lowest — builds yield disk I/O to everything else
    Nice = 10;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # RESCUE SSH: Dropbear on port 2200 (FIFO lane 1)
  # ═══════════════════════════════════════════════════════════════════════════
  systemd.services.rescue-ssh = {
    description = "Rescue SSH (Dropbear on port ${toString rescuePort}) — UNTOUCHABLE";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    preStart = ''
      mkdir -p /etc/dropbear
      if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
        ${pkgs.dropbear}/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
        echo "[rescue-ssh] Generated ed25519 host key"
      fi
      echo "[rescue-ssh] Ready on port ${toString rescuePort}"
    '';

    serviceConfig = {
      Slice = "connectivity.slice";
      Type = "simple";
      ExecStart = "${pkgs.dropbear}/bin/dropbear -F -E -p ${toString rescuePort} -r /etc/dropbear/dropbear_ed25519_host_key";
      Restart = "always";
      RestartSec = 2;
      CPUSchedulingPolicy = "fifo";
      CPUSchedulingPriority = 1;
      IOSchedulingClass = "realtime";
      IOSchedulingPriority = 0;
      OOMScoreAdjust = -1000;
      OOMPolicy = "continue";
      MemoryMin = "20M";
      MemoryMax = "30M";
      MemoryHigh = "25M";
      Nice = -20;
    };
  };

  # DISK WATCHDOG: removed 2026-07-08. This hardcoded, /-only, escalating guard
  # was fully superseded by the data-driven `disk-watchdog-v2` in
  # configuration_system-protection-disk.nix (which watches / via its
  # watches.mounts entry). It was a footgun: `docker image prune -af` nuked
  # tagged images and `nix-collect-garbage -d` destroyed ALL rollback
  # generations. Rule 6 (replace hardcoded, don't extend). All disk defense now
  # lives in cloud-data-disk-protection.json.

  # ═══════════════════════════════════════════════════════════════════════════
  # SWAP CAP DROP-IN: user-1000.slice MemorySwapMax
  # NixOS sliceConfig silently drops MemorySwapMax (not in its allowed-set).
  # environment.etc can't reach the systemd unit pipeline either.
  # systemd.packages IS scanned for lib/systemd/system/*.d/ drop-ins — use it.
  # ═══════════════════════════════════════════════════════════════════════════
  systemd.packages = [
    (pkgs.writeTextDir "lib/systemd/system/user-1000.slice.d/50-swap-cap.conf" ''
      [Slice]
      MemorySwapMax=${userMemSwapMax}
    '')
    # machine.slice MemorySwapMax — same workaround: NixOS sliceConfig drops it.
    (pkgs.writeTextDir "lib/systemd/system/machine.slice.d/50-swap-cap.conf" ''
      [Slice]
      MemorySwapMax=${machineMemSwapMax}
    '')
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # PACKAGES + FIREWALL
  # ═══════════════════════════════════════════════════════════════════════════
  environment.systemPackages = [ pkgs.dropbear ];
  # Rescue dropbear (port ${toString rescuePort}) is reachable only via wg0
  # (configuration_network.nix declares wg0 as trustedInterface, so all
  # ports are accepted from peers in 10.0.0.0/24). No global TCP opening
  # — anyone on the local LAN cannot brute-force the rescue daemon.
}
