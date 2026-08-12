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

  # oom-hotkey: passive evdev watcher, values baked from sysprot.oom_hotkey.
  oomHotkeyPy = pkgs.writeText "oom-hotkey.py" (builtins.replaceStrings
    [ "@KEY@" "@HOLD_MS@" "@SYSRQ_CHAR@" ]
    [ sysprot.oom_hotkey.key (toString sysprot.oom_hotkey.hold_ms) sysprot.oom_hotkey.sysrq_char ]
    (builtins.readFile ./oom-hotkey.py));
  oomHotkeyPython = pkgs.python3.withPackages (p: [ p.evdev ]);

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
  # workloadMemMax/SwapMax (2026-07-18): kernel-enforced hard ceiling on workload.slice.
  # IOWeight alone is a relative priority, not a cap — under sustained saturation it
  # doesn't stop the NVMe queue from staying full (2026-07-18 freeze: freeze-guard's
  # SIGTERM escalation never reached wedged D-state tasks). MemoryMax forces the kernel
  # to OOM-kill inside workload.slice BEFORE reclaim thrash builds into an IO storm —
  # no signal delivery required. MemorySwapMax=0 mirrors nix-daemon: OOM-kill, not swap-thrash.
  workloadMemMax = sysprot.slice_protection.workload_memory_max;
  workloadMemSwapMax = sysprot.slice_protection.workload_memory_swap_max;
  # userMemSwapMax=0 also blocked ZRAM (per-cgroup swap cap can't distinguish
  # zram from disk), defeating the swappiness=150 zram-first design and leaving
  # the desktop with no pressure valve. 2048M lands on zram (prio 100 vs disk -1).
  userMemSwapMax = "2048M";                           # bounded valve → zram (was 0 = file-page thrash, 2026-07-02)

  # Freeze-guard — script lives in freeze-guard.sh (kept out of the Nix
  # module; inline scripts inside flake/nix modules are forbidden here). It
  # is fully DATA-DRIVEN: every threshold, cgroup slice name, voter weight,
  # interval and the comm→unit RESET map are read at RUNTIME from
  # /etc/cloud-data/system-protection.json via jq — nothing is baked in by
  # Nix interpolation. See environment.etc below for how that JSON gets
  # deployed, and freeze-guard.sh for the full voter/escalation logic.
  freezeGuardPkg = pkgs.writeShellApplication {
    name = "freeze-guard";
    text = builtins.readFile ./freeze-guard.sh;
    runtimeInputs = with pkgs; [
      coreutils   # cat, sleep, date, tr, mv, chmod, cut
      procps      # ps
      gnugrep     # grep -Eq
      gawk        # awk PSI/proc parsing
      systemd     # (path already carries this too)
      sudo        # RESET restart escalation
      jq          # runtime config parsing
    ];
  };

  # Prochot-guard — script lives in prochot-guard.sh (kept out of the Nix
  # module; inline scripts inside flake/nix modules are forbidden here). It
  # is fully DATA-DRIVEN: the sustained-strike count and the notify-send
  # target uid are read at RUNTIME from /etc/cloud-data/system-protection.json
  # via jq — nothing is baked in by Nix interpolation.
  prochotGuardPkg = pkgs.writeShellApplication {
    name = "prochot-guard";
    text = builtins.readFile ./prochot-guard.sh;
    runtimeInputs = with pkgs; [
      msr-tools    # rdmsr, wrmsr
      libnotify    # notify-send
      gawk
      coreutils
      jq           # runtime config parsing
      sudo         # sudo -u notify-send as the session user
    ];
  };

  # rescue-ssh preStart (host-key keygen) — script lives in
  # rescue-ssh-prestart.sh (kept out of the Nix module; inline scripts inside
  # flake/nix modules are forbidden here). The rescue port it logs is read at
  # RUNTIME from /etc/cloud-data/system-protection.json via jq.
  rescueSshPrestartPkg = pkgs.writeShellApplication {
    name = "rescue-ssh-prestart";
    text = builtins.readFile ./rescue-ssh-prestart.sh;
    runtimeInputs = with pkgs; [
      dropbear
      jq           # runtime config parsing
      util-linux   # logger
    ];
  };
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
  # "msr" — prochot-guard reads/clears MSR 0x1FC (BD_PROCHOT, the 200MHz clamp)
  boot.kernelModules = [ "msr" ] ++ lib.optional sysprot.kernel_watchdog.enable sysprot.kernel_watchdog.module;
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

  # RESET capability (2026-07-26): root-watchdog holds only CAP_KILL +
  # CAP_DAC_READ_SEARCH — `systemctl restart <unit>` needs root/polkit, which
  # those caps don't grant. Scope a NOPASSWD sudo rule to EXACTLY the units
  # freeze-guard is allowed to restart, data-driven from sysprot.watchdog.reset_units
  # (the JSON is SoT — no unit can be added here without also being declared
  # there). Empty-string map values (user-session respawns) never generate a
  # command, so they're naturally excluded.
  security.sudo.extraRules = [{
    users = [ "root-watchdog" ];
    commands = map (unit: {
      command = "${pkgs.systemd}/bin/systemctl restart ${unit}";
      options = [ "NOPASSWD" ];
    }) (lib.unique (lib.filter (u: u != "") (lib.attrValues sysprot.watchdog.reset_units)));
  }];

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
  # SYSTEM-PROTECTION JSON — deployed for freeze-guard.sh / prochot-guard.sh /
  # rescue-ssh-prestart.sh to read at RUNTIME via jq (distinct path from the
  # disk module's /etc/cloud-data/disk-protection.json — different JSON file).
  # A missing/unreadable/unparseable file makes those scripts exit non-zero
  # rather than silently running with empty thresholds.
  # ═══════════════════════════════════════════════════════════════════════════
  environment.etc."cloud-data/system-protection.json".source = ./cloud-data-system-protection.json;

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
    path = with pkgs; [ coreutils procps gnugrep gawk systemd sudo ];
    serviceConfig = {
      User = "root-watchdog";
      Group = "root-watchdog";
      # CAP_DAC_OVERRIDE added (2026-08-07) alongside the state-publish feature
      # below: /run is root:root 0755, and root-watchdog otherwise cannot
      # create /run/freeze-guard.json (write-temp-then-mv needs to create the
      # sibling .tmp file in that directory). CAP_KILL/CAP_DAC_READ_SEARCH
      # alone were sufficient for the kill path but not for writing state.
      AmbientCapabilities = [ "CAP_KILL" "CAP_DAC_READ_SEARCH" "CAP_DAC_OVERRIDE" ];
      CapabilityBoundingSet = [ "CAP_KILL" "CAP_DAC_READ_SEARCH" "CAP_DAC_OVERRIDE" ];
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
    script = "${freezeGuardPkg}/bin/freeze-guard";
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
      MemoryMax = workloadMemMax;
      MemorySwapMax = workloadMemSwapMax;
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
      # oomd override (2026-08-07): was only set on the parent "user" slice
      # (below) and root/system slices — systemd-oomd reads the limit on the
      # cgroup it's actually monitoring, and live inspection showed 0% here on
      # user-1000.slice itself, i.e. oomd's memory-PSI kill path was
      # effectively disabled for this user's session. Set it directly.
      ManagedOOMMemoryPressureLimit = sysprot.oomd.pressure_limit;
    };
  };

  # Compositor NEVER swaps (2026-07-11). MemorySwapMax=0 on the Plasma user units
  # only — NOT the whole user-1000.slice (that whole-slice swap=0 caused the
  # 2026-07-02 file-page-thrash freeze). Data-driven from compositor_no_swap.units.
  # Xwayland is a child of kwin_wayland → shares its cgroup → inherits swap=0.
  # overrideStrategy = "asDropin" is MANDATORY (2026-07-22 incident): without it
  # NixOS emits a FULL replacement unit (only MemorySwapMax, no ExecStart) that
  # shadows the plasma-shipped unit in /etc/systemd/user — systemd then refuses
  # to start plasmashell/kwin after login = black desktop (gen 48).
  # MUST be systemd.user.units RAW TEXT, not systemd.user.services (2026-07-24
  # incident): the services generator injects its default Environment=PATH=
  # (coreutils/findutils/grep/sed/systemd — NO kwin) into the drop-in, which
  # overrides the vendor unit env; kwin_wayland_wrapper resolves `kwin_wayland`
  # by bare name via PATH → compositor died at exec before its first log line,
  # wrapper kept the DBus name + a dead wayland-0 socket, unit stayed "active",
  # every Qt client blocked in the accept queue → all session units hit
  # Type=dbus timeouts after login. Raw unit text emits ONLY the lines below.
  # See a0_tasks/PLAN_plasma-kwin-dropin-path-poison.md for the full forensics.
  systemd.user.units = lib.genAttrs
    (map (u: "${u}.service") sysprot.compositor_no_swap.units) (_: {
      overrideStrategy = "asDropin";
      text = ''
        [Service]
        MemorySwapMax=${sysprot.compositor_no_swap.MemorySwapMax}
      '';
    });

  # prochot-guard (2026-07-11): detect EC BD_PROCHOT hardware clamps — the
  # 200MHz incident. All cores clamped to 200MHz (below the 400MHz software
  # floor) at 40°C by a falsely-asserted EC PROCHOT pin; PSI/oomd/freeze-guard
  # were ALL blind (they measure stalls, not clock speed — a 20x-slowed CPU
  # reads as "busy but healthy"). Compares scaling_cur_freq vs scaling_min_freq
  # each tick; sustained below floor = hardware clamp → CRIT journal +
  # notify-send (fix = EC power-drain) + best-effort MSR 0x1FC bit0 clear.
  # Data-driven from sysprot.prochot_guard.
  systemd.services.prochot-guard = {
    description = "Detect EC BD_PROCHOT hardware CPU clamp (PSI-invisible)";
    serviceConfig = {
      Type = "oneshot";
      Slice = "connectivity.slice";   # untouchable island — must run even when starved
    };
    script = "${prochotGuardPkg}/bin/prochot-guard";
  };
  systemd.timers.prochot-guard = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "${toString sysprot.prochot_guard.interval_sec}s";
    };
  };

  # oom-hotkey (2026-07-16): hold RIGHTCTRL ≥ hold_ms → write sysrq_char to
  # /proc/sysrq-trigger = OOM kill IN KERNEL CONTEXT, so it can't get stuck
  # behind busy/starved userspace (same guarantee as Alt+SysRq+F, but a single
  # key). PASSIVE evdev watcher (no device grab) → zero latency, RIGHTCTRL still
  # works normally, a quick chord never fires. Runs in the untouchable island so
  # it always gets scheduled. Needs kernel.sysrq bit 64 (mask 244, set above).
  systemd.services.oom-hotkey = lib.mkIf sysprot.oom_hotkey.enable {
    description = "RIGHTCTRL long-press → kernel-direct OOM via SysRq (PSI-invisible escape hatch)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${oomHotkeyPython}/bin/python3 ${oomHotkeyPy}";
      Slice = sysprot.oom_hotkey.slice;      # untouchable island
      CPUSchedulingPolicy = "rr";
      CPUSchedulingPriority = 1;
      IOSchedulingClass = "realtime";
      IOSchedulingPriority = 0;
      OOMScoreAdjust = lib.mkForce (-1000);  # never killed
      MemoryMin = sysprot.reservation.memory_min;
      Nice = -20;
      Restart = "always";
      RestartSec = 2;
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

    preStart = "${rescueSshPrestartPkg}/bin/rescue-ssh-prestart";

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
  environment.systemPackages = [
    pkgs.dropbear
    pkgs.msr-tools   # rdmsr/wrmsr — manual BD_PROCHOT (MSR 0x1FC) diagnosis, used by prochot-guard
  ];
  # Rescue dropbear (port ${toString rescuePort}) is reachable only via wg0
  # (configuration_network.nix declares wg0 as trustedInterface, so all
  # ports are accepted from peers in 10.0.0.0/24). No global TCP opening
  # — anyone on the local LAN cannot brute-force the rescue daemon.
}
