# Plan: Universal Resource Bouncer — System That NEVER Freezes

## Context

Surface Pro 8, 7.6GB RAM, froze hard during a nix build. The kernel locked up because nothing stopped processes from consuming ALL resources. earlyoom at 5% was a band-aid on one symptom. The real fix: a **universal bouncer** using systemd cgroups v2 that enforces resource budgets on EVERYTHING — CPU, memory, I/O — so the desktop ALWAYS stays responsive regardless of what any process tries to do.

Additionally: two `nix.settings` blocks (lines 30-34 and 635-645) — the first block's `substituters`/`trusted-public-keys` are silently lost.

## File

`/home/diego/Mounts/Git/unix/aa_nixos-surface_host/src/configuration.nix`

## Architecture: The Bouncer

```
┌─────────────────────────────────────────────────────────┐
│                    7.6 GB RAM / 4 cores                 │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │  SYSTEM.SLICE (kernel, compositor, audio, sshd)  │   │
│  │  MemoryMin=2G  CPUWeight=9999  IOWeight=9999     │   │
│  │  → ALWAYS gets resources first. NEVER starved.   │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  ┌────────────────┐  ┌──────────────┐  ┌────────────┐   │
│  │  USER SLICE    │  │ MACHINE SLICE│  │ NIX-DAEMON │   │
│  │  browsers,     │  │ docker,      │  │ nix builds │   │
│  │  editors, etc  │  │ podman       │  │            │   │
│  │                │  │              │  │            │   │
│  │  MemHigh=5G    │  │ MemHigh=3G   │  │ MemHigh=4G │   │
│  │  MemMax=6G     │  │ MemMax=4G    │  │ MemMax=5G  │   │
│  │  CPU=300%      │  │ CPU=200%     │  │ CPU=200%   │   │
│  │  IOWeight=500  │  │ IOWeight=200 │  │ IOWeight=50│   │
│  └────────────────┘  └──────────────┘  └────────────┘   │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │  SAFETY NETS: earlyoom (10%) → zram → sysctl     │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘

If nix build tries to use 6GB → THROTTLED at 4G, KILLED at 5G
If browser tries to eat all CPU → CAPPED at 300% (3 cores)
If container tries to hog I/O → DEPRIORITIZED, system I/O first
Desktop compositor? GUARANTEED 2GB + highest CPU/IO priority. Always.
```

## Changes (all in `configuration.nix`)

### 1. Fix: Merge two `nix.settings` blocks

**Delete** first block (lines 30-34), **merge into** second block (lines 635-645), reduce `max-jobs` 4→2.

```nix
# Lines 23-34 become just the comment header + redirect:
  # ═══════════════════════════════════════════════════════════════════════════
  # NIX SETTINGS (consolidated — see CONTAINERS section below)
  # ═══════════════════════════════════════════════════════════════════════════

# Lines 635-645 become the single merged block:
  nix.settings = {
    max-jobs = 2;
    substituters = [ "https://cache.nixos.org" ];
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    trusted-users = [ "root" "diego" ];
    build-dir = "/nix/tmp";
  };
```

### 2. Replace earlyoom section (lines 530-548) with full RESOURCE BOUNCER

Replace the entire OOM PROTECTION section with the bouncer. This is the main change — one big coherent block containing:

#### 2a. Kernel sysctl tuning

```nix
  boot.kernel.sysctl = {
    "vm.min_free_kbytes" = 262144;         # 256MB reserved for kernel
    "vm.swappiness" = 150;                 # With zram, prefer compressed swap
    "vm.dirty_ratio" = 10;                 # Sync writeback at ~760MB dirty
    "vm.dirty_background_ratio" = 5;       # Async writeback at ~380MB dirty
    "vm.watermark_scale_factor" = 500;     # Aggressive kswapd wake-up
  };
```

#### 2b. zram compressed swap

```nix
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;   # 3.8GB → ~11GB effective swap
    priority = 100;       # Use before disk swap
  };
```

#### 2c. earlyoom (improved thresholds)

```nix
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 10;          # SIGTERM at ~760MB free (was 5%)
    freeSwapThreshold = 10;
    freeMemKillThreshold = 5;       # SIGKILL escalation at ~380MB
    freeSwapKillThreshold = 5;
    enableNotifications = true;
    reportInterval = 0;
    extraArgs = [
      "--prefer" "^(brave|firefox|chromium|electron|nix-daemon|nix-build|nix)$"
      "--avoid" "^(kwin|plasmashell|plasma|sddm|Xwayland|pipewire|wireplumber|systemd|earlyoom|dbus)$"
    ];
  };
```

#### 2d. Systemd slice budgets (THE BOUNCER)

```nix
  # System slice: compositor, audio, sshd — GUARANTEED resources
  systemd.slices."system".sliceConfig = {
    MemoryMin = "2G";
    MemoryLow = "3G";
    CPUWeight = 9999;
    IOWeight = 9999;
  };

  # User slice: browsers, editors, terminals — CAPPED
  systemd.slices."user-".sliceConfig = {
    MemoryHigh = "5G";
    MemoryMax = "6G";
    CPUWeight = 100;
    CPUQuota = "300%";        # Max 3 of 4 cores
    IOWeight = 500;
  };

  # Machine slice: Docker, Podman, Waydroid — CAPPED
  systemd.slices."machine".sliceConfig = {
    MemoryHigh = "3G";
    MemoryMax = "4G";
    CPUWeight = 50;
    CPUQuota = "200%";        # Max 2 cores
    IOWeight = 200;
  };
```

#### 2e. nix-daemon hard limits

```nix
  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "4G";
    MemoryMax = "5G";
    CPUQuota = "200%";        # Max 2 cores
    IOWeight = 50;
  };
```

### 3. Disk space watchdog (new systemd timer, after bouncer section)

A timer that checks disk space every 5 minutes and triggers nix GC if /nix is >90% full.

```nix
  systemd.timers."disk-watchdog" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
    };
  };

  systemd.services."disk-watchdog" = {
    serviceConfig.Type = "oneshot";
    script = ''
      USAGE=$(${pkgs.coreutils}/bin/df /nix --output=pcent | tail -1 | tr -d ' %')
      if [ "$USAGE" -gt 90 ]; then
        echo "Disk >90% — running nix GC" | ${pkgs.systemd}/bin/systemd-cat -t disk-watchdog -p warning
        ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 3d
      fi
    '';
  };
```

## What NOT to change

- Swap file (already in `hardware-configuration.nix`)
- Docker/Podman daemon config (they run inside machine.slice automatically)
- Waydroid config (already disabled auto-start, capped by machine.slice)
- `vm.overcommit_memory` (keep default 0)
- No `cgroup_no_v1=all` kernel param (NixOS 24.11 already uses cgroups v2 by default)
- No `systemd.oomd` (earlyoom is simpler and proven, oomd can conflict)
- No per-app limits (browsers, firefox) — user.slice handles them collectively
- No I/O bandwidth caps (IOWeight is sufficient, bandwidth caps need device-specific tuning)

## Verification

```bash
# Build and test
~/Mounts/Git/unix/aa_nixos-surface_host/build.sh  # select test option

# After reboot:
zramctl && swapon --show                                    # zram active
sysctl vm.min_free_kbytes vm.swappiness                     # sysctl applied
systemctl show nix-daemon | grep -E 'Memory|CPU|IO'         # daemon limits
systemctl show user-.slice | grep -E 'Memory|CPU'           # user limits
systemctl show system.slice | grep -E 'Memory|CPU'          # system guarantees
systemctl show machine.slice | grep -E 'Memory|CPU'         # container limits
systemctl status earlyoom                                    # earlyoom running
nix show-config | grep -E 'max-jobs|substituters'           # merged settings
systemctl list-timers | grep disk                            # watchdog running
```
