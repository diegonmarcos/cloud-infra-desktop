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
  # ── Hardware specs (Surface Pro 8) ─────────────────────────────────────
  cpus = 8;       # logical CPUs (4 cores × 2 threads)
  ramMB = 8192;   # 8GB RAM
  rescuePort = 2200;

  # ── Data-driven freeze-proof policy ────────────────────────────────────
  # Single source of truth, ALSO read by build.sh (_apply_daemon_caps) so the
  # caps are enforced both at boot (here) and live before every build (engine).
  sysprot = builtins.fromJSON (builtins.readFile ./cloud-data-system-protection.json);

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
  userMemMax = "${toString (ramMB * 70 / 100)}M";     # 5734M (was 58%=4751M)
  userMemHigh = "${toString (ramMB * 55 / 100)}M";    # 4505M (was 38%=3112M — below working set = reclaim thrash)
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
  # EARLYOOM: last resort OOM killer (RR scheduler)
  # ═══════════════════════════════════════════════════════════════════════════
  # earlyoom — deep backstop beneath systemd-oomd. Data-driven (sysprot.earlyoom).
  # EVIDENCE FIX (2026-06-27): the frozen system's live earlyoom (-s 5,3) only fired
  # when free-swap <= 5%, which NEVER happens with 20G swap → it never fired at all.
  # free_swap=100 removes that gate so earlyoom fires on LOW MEMORY alone. `nix` is
  # also no longer in --avoid (was the other reason a runaway build was never killed).
  services.earlyoom = {
    enable = true;
    freeMemThreshold = sysprot.earlyoom.free_mem;
    freeSwapThreshold = sysprot.earlyoom.free_swap;          # 100 = swap-gate removed → fire on mem alone
    freeMemKillThreshold = sysprot.earlyoom.free_mem_kill;
    freeSwapKillThreshold = sysprot.earlyoom.free_swap_kill; # 100 = swap-gate removed
    enableNotifications = true;
    reportInterval = 0;
    extraArgs = [
      "--prefer" "^(brave|firefox|chromium|electron)$"
      "--avoid" "^(kwin|plasmashell|plasma|sddm|Xwayland|pipewire|wireplumber|systemd|earlyoom|dbus)$"
    # nix deliberately NOT in --avoid — earlyoom must be able to kill a runaway nix build
    ];
  };

  systemd.services.earlyoom.serviceConfig = {
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

      # $2 = "full" (mem/io: all tasks stalled) or "some" (cpu: any task stalled).
      psi_avg10() {
        awk -v k="$2" '$1 == k { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { sub(/avg10=/,"",$i); print $i } }' "/proc/pressure/$1" 2>/dev/null
      }

      # Pick the top offender by $1 sort key (rss or pcpu), skipping already-killed
      # pids ($2 = space-separated exclusion list). prefer_kill first, then any
      # non-avoid_kill process. Prints "pid metric comm".
      pick_victim() {
        local key="$1" skip="$2" excl=""
        [ -n "$skip" ] && excl="^($(echo "$skip" | tr ' ' '|')) "
        local cmd="ps -eo pid=,$key=,comm= --sort=-$key"
        local line
        line=$($cmd | grep -E -- "$PREFER" | grep -E -v -- "$AVOID" | { [ -n "$excl" ] && grep -E -v -- "$excl" || cat; } | head -n1)
        [ -z "$line" ] && line=$($cmd | grep -E -v -- "$AVOID" | { [ -n "$excl" ] && grep -E -v -- "$excl" || cat; } | head -n1)
        echo "$line"
      }

      # Signal picker: graceful SIGTERM for node/claude so Claude Code can print
      # its "claude --resume" hint on the way out; hard SIGKILL for everything
      # else. NOT a whitelist — node/claude still gets killed, just cleanly.
      do_kill() {
        case "$2" in
          node|claude) kill -TERM "$1" 2>/dev/null || true; echo TERM ;;
          *)           kill -9    "$1" 2>/dev/null || true; echo KILL ;;
        esac
      }

      # PSI IS THE ONLY KILL METRIC. No absolute CPU%/RSS/mem% triggers — those
      # cause false kills (Claude died at PSI=0). We act ONLY on real kernel stall
      # (PSI 'some'/'full' avg10 over limit); the victim is then RANKED by %cpu
      # (cpu breach) or RSS (mem/io breach) — ranking is victim-selection, not the
      # trigger. Graceful SIGTERM for node/claude via do_kill.
      echo "[freeze-guard] online as $(id -un); PSI-ONLY trigger — cpuPSI(some)>$CPU_LIMIT | memPSI(full)>$MEM_LIMIT | ioPSI(full)>$IO_LIMIT; max $MAX_KILLS kills/tick"
      while :; do
        cpu=$(psi_avg10 cpu some);    cpu=''${cpu:-0}
        mem=$(psi_avg10 memory full); mem=''${mem:-0}
        io=$(psi_avg10 io full);      io=''${io:-0}

        killed=""; n=0
        while [ "$n" -lt "$MAX_KILLS" ] && \
              awk "BEGIN { exit !($cpu+0 > $CPU_LIMIT || $mem+0 > $MEM_LIMIT || $io+0 > $IO_LIMIT) }"; do
          # Rank by %cpu when CPU is the breaching signal, else by RSS.
          if awk "BEGIN { exit !($cpu+0 > $CPU_LIMIT) }"; then key="pcpu"; else key="rss"; fi
          set -- $(pick_victim "$key" "$killed")
          pid="$1"; metric="$2"; name="$3"
          [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
          sig=$(do_kill "$pid" "$name")
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
  # LOCAL TIER: SYSTEM SLICES (3-tier hierarchy)
  # ═══════════════════════════════════════════════════════════════════════════

  # kernel.slice — uncapped, Linux essentials
  systemd.slices."kernel" = {
    description = "Kernel-essential services — no cap";
  };

  # os-essentials.slice — 95% cap, protection + connectivity
  systemd.slices."os-essentials" = {
    description = "OS-essential services — protection, connectivity";
    sliceConfig = {
      CPUQuota = osEssentialsCpuQuota;
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
  systemd.slices."workload" = {
    description = "Workload services — docker, containers, nix-daemon";
    sliceConfig = {
      CPUQuota = workloadCpuQuota;
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

  # ═══════════════════════════════════════════════════════════════════════════
  # DISK WATCHDOG: escalating cleanup
  # ═══════════════════════════════════════════════════════════════════════════
  systemd.timers."disk-watchdog" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
    };
  };

  systemd.services."disk-watchdog" = {
    serviceConfig.Type = "oneshot";
    path = with pkgs; [ coreutils findutils systemd nix util-linux ];
    script = ''
      WARN=85
      CRIT=90
      EMERG=95

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      echo "[disk-watchdog] Root disk usage: ''${USAGE}%"

      [ "$USAGE" -lt "$WARN" ] && exit 0

      echo "[disk-watchdog] WARNING: ''${USAGE}% — starting cleanup"

      # Level 1 (>85%): Safe targets
      find /tmp -type f -atime +2 -delete 2>/dev/null || true
      find /var/tmp -type f -atime +2 -delete 2>/dev/null || true
      journalctl --vacuum-size=100M 2>/dev/null || true

      find /home/*/. -maxdepth 0 2>/dev/null | while read home; do
        find "$home/.cache" -type f -atime +7 -delete 2>/dev/null || true
      done

      if command -v docker >/dev/null 2>&1; then
        docker container prune -f 2>/dev/null || true
        docker image prune -f 2>/dev/null || true
        docker builder prune -f --keep-storage=1G 2>/dev/null || true
      fi
      if command -v podman >/dev/null 2>&1; then
        podman system prune -f 2>/dev/null || true
      fi

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      [ "$USAGE" -lt "$CRIT" ] && echo "[disk-watchdog] Resolved at ''${USAGE}%" && exit 0

      # Level 2 (>90%): Aggressive
      echo "[disk-watchdog] Level 2: aggressive cleanup (''${USAGE}%)"
      journalctl --vacuum-size=50M 2>/dev/null || true

      if command -v docker >/dev/null 2>&1; then
        docker image prune -af 2>/dev/null || true
        docker volume prune -f 2>/dev/null || true
      fi

      nix-collect-garbage --delete-older-than 3d 2>/dev/null || true

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      [ "$USAGE" -lt "$EMERG" ] && echo "[disk-watchdog] Resolved at ''${USAGE}%" && exit 0

      # Level 3 (>95%): Emergency
      echo "[disk-watchdog] CRITICAL: ''${USAGE}% — emergency cleanup"
      find /var/log -name "*.log" -size +10M -exec truncate -s 1M {} \; 2>/dev/null || true
      find /var/log -name "*.gz" -delete 2>/dev/null || true
      find /var/log -name "*.old" -delete 2>/dev/null || true
      nix-collect-garbage -d 2>/dev/null || true

      USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
      echo "[disk-watchdog] Final: ''${USAGE}%"
      if [ "$USAGE" -ge "$EMERG" ]; then
        echo "[disk-watchdog] ALERT: still ''${USAGE}% — manual intervention needed"
      fi
    '';
  };

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
