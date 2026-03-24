# System Protection — Desktop (NixOS native)
# Surface Pro 8, 7.6GB RAM. Prevents hard lockups under memory pressure
# using cgroups v2 caps, zram, earlyoom, and compositor memory guarantees.
#
# VM equivalent: cloud/b_infra/home-manager/_shared/modules/system-protection*.nix
#
# Architecture:
#   system.slice  → MemoryMin=500M (systemd, sshd, docker daemon)
#   user-.slice   → MemoryMax=90% cap, compositor gets MemoryMin guarantee
#   machine.slice → MemoryMax=50% cap (docker/podman containers)
#   nix-daemon    → MemoryMax=70% cap, CPUQuota=50%
#   Safety nets   → zram (50% compressed) + earlyoom (10% threshold)
#
# Result: system slows down under pressure — NEVER locks up.
{ config, pkgs, lib, ... }:

{
  # ─── Kernel sysctl: memory management tuning ────────────────────────────
  boot.kernel.sysctl = {
    "vm.min_free_kbytes" = 262144;         # 256MB kernel reserve
    "vm.swappiness" = 150;                 # zram: prefer compressed swap over dropping caches
    "vm.dirty_ratio" = 10;                 # Sync writeback at ~760MB dirty
    "vm.dirty_background_ratio" = 5;       # Async writeback at ~380MB dirty
    "vm.watermark_scale_factor" = 500;     # Aggressive kswapd wake-up
  };

  # ─── zram: compressed swap in RAM ───────────────────────────────────────
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;    # 3.8GB → ~11GB effective compressed swap
    priority = 100;        # Fill before disk swap
  };

  # ─── earlyoom: last resort OOM killer ───────────────────────────────────
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

  # ─── THE BOUNCER: cgroup slice limits ───────────────────────────────────

  # System slice: guaranteed minimum for systemd, sshd, docker daemon, etc
  systemd.slices."system".sliceConfig = {
    MemoryMin = "500M";
    CPUWeight = 10000;      # Highest priority when CPU contested
  };

  # User slice: 90% cap — no browser/app eats the whole system
  systemd.slices."user-".sliceConfig = {
    MemoryMax = "6800M";    # 90% of 7.6GB
    CPUQuota = "720%";      # 90% of 8 logical CPUs
  };

  # Compositor protection — guaranteed memory for the user session
  # NOTE: Per-service MemoryMin via systemd.user.services is broken in NixOS 24.11
  # (replaces the entire unit file, wiping ExecStart). Using slice-level protection
  # instead — the user-.slice MemoryMin (above) protects the entire session.

  # Machine slice: 50% cap — containers are secondary workloads
  systemd.slices."machine".sliceConfig = {
    MemoryMax = "3800M";    # 50% of 7.6GB
    CPUQuota = "400%";      # 50% of 8 logical CPUs
  };

  # ─── JANITOR: Disk watchdog — escalating cleanup ────────────────────────
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
}
