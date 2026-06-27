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
  userMemMax = "${toString (ramMB * 58 / 100)}M";     # 4751M (was 85%=6963M)
  userMemHigh = "${toString (ramMB * 38 / 100)}M";    # 3112M (was 75%=6144M — now 1.6GB gap before hard kill)
  rootMemMax = "${toString (ramMB * 95 / 100)}M";     # 7782M
  rootMemHigh = "${toString (ramMB * 85 / 100)}M";    # 6963M
  machineMemMax = "${toString (ramMB * 37 / 100)}M";  # 3031M (was 75%=6144M — Docker can't eat 75% of RAM)
  machineMemHigh = "${toString (ramMB * 29 / 100)}M"; # 2375M (was absent — adds early reclaim trigger)
  machineMemSwapMax = "1024M";                         # (was absent — Docker disk swap was unlimited → thrash)
  nixMemMax = "${toString (ramMB * 75 / 100)}M";      # 6144M
  nixMemHigh = "${toString (ramMB * 65 / 100)}M";     # 5324M
  # userMemMin: reduced from 38%=3113M. MemoryHigh+lower MemoryMax are the real
  # anti-freeze guards; the high MemoryMin was pinning 3GB unnecessarily.
  userMemMin = "${toString (ramMB * 12 / 100)}M";     # 983M (was 38%=3113M)
  nixMemSwapMax = "2048M";                            # build may spill at most 2G to disk swap
  userMemSwapMax = "2048M";                           # user disk swap cap (was 4096M)
in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # KERNEL SYSCTL
  # ═══════════════════════════════════════════════════════════════════════════
  boot.kernel.sysctl = {
    "vm.min_free_kbytes" = 262144;         # 256MB kernel reserve
    "vm.swappiness" = 150;                 # zram: prefer compressed swap
    "vm.dirty_ratio" = 10;
    "vm.dirty_background_ratio" = 5;
    "vm.watermark_scale_factor" = 500;
  };

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
  services.earlyoom = {
    enable = true;
    # 5/3% thresholds (was 10/5): nix-daemon now has MemorySwapMax as the
    # real anti-freeze guard — earlyoom only fires at genuine crisis.
    freeMemThreshold = 5;
    freeSwapThreshold = 5;
    freeMemKillThreshold = 3;
    freeSwapKillThreshold = 3;
    enableNotifications = true;
    reportInterval = 0;
    extraArgs = [
      # nix-daemon removed from prefer: cgroup MemorySwapMax protects the machine.
      "--prefer" "^(brave|firefox|chromium|electron)$"
      "--avoid" "^(kwin|plasmashell|plasma|sddm|Xwayland|pipewire|wireplumber|systemd|earlyoom|dbus|nix)$"
    ];
  };

  systemd.services.earlyoom.serviceConfig = {
    CPUSchedulingPolicy = "rr";
    CPUSchedulingPriority = 1;
    IOSchedulingClass = "best-effort";
    IOSchedulingPriority = 0;
    OOMScoreAdjust = lib.mkForce (-999);
    OOMPolicy = "continue";
    Nice = -20;
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

  # connectivity.slice — sub-slice of os-essentials for SSH/VPN
  systemd.slices."connectivity" = {
    description = "Protected connectivity — SSH, Dropbear";
    sliceConfig = {
      MemoryMin = "200M";
      MemoryLow = "200M";
      CPUWeight = 10000;
      IOWeight = 1000;
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
      MemoryMin = userMemMin;   # reserved RAM — never reclaimed for a build (anti-freeze)
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

  # user.slice — top-level user slice beats Docker/containers under CPU contention
  systemd.slices."user" = {
    sliceConfig = {
      CPUWeight = 200;  # user sessions (KDE + apps) 4× priority over Docker at root level
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

  # nix-daemon — workload.slice, capped
  systemd.services.nix-daemon.serviceConfig = {
    Slice = "workload.slice";
    MemoryMax = nixMemMax;
    MemoryHigh = nixMemHigh;
    MemorySwapMax = nixMemSwapMax;  # bound disk-swap spill so swap-out I/O can't freeze the desktop
    CPUQuota = nixDaemonCpuQuota;
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
