# System Protection — Desktop (NixOS native)
# Surface Pro 8, 8GB RAM. Prevents hard lockups under memory pressure.
#
# Architecture:
#   FIFO (lane 1): sshd, rescue-ssh (Dropbear) — absolute CPU priority, NEVER waits
#   RR   (lane 2): earlyoom — real-time round-robin, protection daemon
#   CFS  (lane 3): everything else — normal fair share with caps
#
#   connectivity  → MemoryMin=200M (sshd, rescue-ssh) — kernel-guaranteed, NEVER reclaimed
#   system.slice  → MemoryMin=500M (systemd, docker daemon)
#   user-.slice   → MemoryMax=90% cap, compositor gets MemoryMin guarantee
#   machine.slice → MemoryMax=50% cap (docker/podman containers)
#   nix-daemon    → MemoryMax=70% cap, CPUQuota=50%
#   Safety nets   → zram (50% compressed) + earlyoom (10% threshold)
#
# VM equivalent: cloud/b_infra/home-manager/_shared/modules/system-protection*.nix
# HM desktop:    unix/ba_flakes_desktop/src/modules/system-protection-guardrails.nix (user-level PATH wrappers only)
{ config, pkgs, lib, ... }:

let
  rescuePort = 2200;
in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # KERNEL SYSCTL: memory management tuning
  # ═══════════════════════════════════════════════════════════════════════════
  boot.kernel.sysctl = {
    "vm.min_free_kbytes" = 262144;         # 256MB kernel reserve
    "vm.swappiness" = 150;                 # zram: prefer compressed swap over dropping caches
    "vm.dirty_ratio" = 10;                 # Sync writeback at ~760MB dirty
    "vm.dirty_background_ratio" = 5;       # Async writeback at ~380MB dirty
    "vm.watermark_scale_factor" = 500;     # Aggressive kswapd wake-up
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # ZRAM: compressed swap in RAM
  # ═══════════════════════════════════════════════════════════════════════════
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;    # ~4GB → ~12GB effective compressed swap
    priority = 100;        # Fill before disk swap
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # EARLYOOM: last resort OOM killer (RR lane 2)
  # ═══════════════════════════════════════════════════════════════════════════
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 10;          # SIGTERM at ~760MB free
    freeSwapThreshold = 10;
    freeMemKillThreshold = 5;       # SIGKILL at ~380MB free
    freeSwapKillThreshold = 5;
    enableNotifications = true;
    reportInterval = 0;
    extraArgs = [
      "--prefer" "^(brave|firefox|chromium|electron|nix-daemon|nix-build|nix)$"
      "--avoid" "^(kwin|plasmashell|plasma|sddm|Xwayland|pipewire|wireplumber|systemd|earlyoom|dbus)$"
    ];
  };

  # Earlyoom: RR scheduler (lane 2) — real-time but time-sliced among RR peers
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
  # CONNECTIVITY SLICE: kernel-guaranteed memory for SSH/Dropbear
  # ═══════════════════════════════════════════════════════════════════════════
  # cgroups v2 MemoryMin is a HARD guarantee — kernel will NEVER reclaim this.
  # OOMScoreAdjust is just a hint; MemoryMin is the real protection.
  # Lesson from cloud VMs: OOMScoreAdjust=-1000 failed under extreme pressure,
  # but MemoryMin in a dedicated slice survived.
  systemd.slices."connectivity" = {
    description = "Protected connectivity slice — SSH, Dropbear";
    sliceConfig = {
      MemoryMin = "200M";
      MemoryLow = "200M";
      CPUWeight = 10000;
      IOWeight = 1000;
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # FIFO SCHEDULER (lane 1): sshd — NEVER waits, preempts ALL normal processes
  # ═══════════════════════════════════════════════════════════════════════════
  # Proven by stress test: SSH hung with CPUWeight=10000 but survived with FIFO.
  # FIFO is kernel-enforced real-time scheduling — runs BEFORE any CFS process.
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

  # ═══════════════════════════════════════════════════════════════════════════
  # RESCUE SSH: Dropbear on port 2200 (FIFO lane 1)
  # ═══════════════════════════════════════════════════════════════════════════
  # Independent SSH daemon — survives even if sshd is misconfigured or down.
  # Uses FIFO scheduler so it's always reachable under any load.
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
      # FIFO lane 1 — absolute priority
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
  # THE BOUNCER: cgroup slice limits
  # ═══════════════════════════════════════════════════════════════════════════

  # System slice: guaranteed minimum for systemd, sshd, docker daemon, etc
  systemd.slices."system".sliceConfig = {
    MemoryMin = "500M";
    CPUWeight = 10000;      # Highest priority when CPU contested
  };

  # User slice: 90% cap — no browser/app eats the whole system
  systemd.slices."user-".sliceConfig = {
    MemoryMax = "6800M";    # 90% of ~7.6GB
    CPUQuota = "720%";      # 90% of 8 logical CPUs
  };

  # Machine slice: 50% cap — containers are secondary workloads
  systemd.slices."machine".sliceConfig = {
    MemoryMax = "3800M";    # 50% of ~7.6GB
    CPUQuota = "400%";      # 50% of 8 logical CPUs
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # NIX-DAEMON: memory + CPU caps (builds can eat everything otherwise)
  # ═══════════════════════════════════════════════════════════════════════════
  systemd.services.nix-daemon.serviceConfig = {
    MemoryMax = "5400M";     # ~70% of 7.6GB
    MemoryHigh = "4800M";    # throttle before hard limit
    CPUQuota = "400%";       # 50% of 8 logical CPUs
    OOMScoreAdjust = 250;    # prefer killing nix over desktop
    IOWeight = 50;
    Nice = 10;
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # JANITOR: Disk watchdog — escalating cleanup
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

      # Desktop: clean user caches
      find /home/*/. -maxdepth 0 2>/dev/null | while read home; do
        find "$home/.cache" -type f -atime +7 -delete 2>/dev/null || true
      done

      # Docker/Podman cleanup
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
  # PACKAGES: dropbear for rescue SSH
  # ═══════════════════════════════════════════════════════════════════════════
  environment.systemPackages = [ pkgs.dropbear ];

  # ═══════════════════════════════════════════════════════════════════════════
  # FIREWALL: allow rescue SSH port
  # ═══════════════════════════════════════════════════════════════════════════
  networking.firewall.allowedTCPPorts = [ rescuePort ];
}
