# Containers: Podman, libvirt, Waydroid
#
# Docker daemon configuration is in docker-daemon.nix and its sub-modules.
# This file owns everything else: Podman, libvirtd, Waydroid.
{ config, pkgs, lib, nurpkgs, ... }:

let
  # Data-driven Waydroid resource policy (src/modules/waydroid.json).
  waydroidCfg  = builtins.fromJSON (builtins.readFile ./waydroid.json);
  wdCg         = waydroidCfg.cgroup;
  # cgroup2 cpu.max = "<quota_us> <period_us>"; quota = cores * period.
  cpuMaxQuota  = wdCg.cpu_max_cores * wdCg.cpu_period_us;
  cpuMaxLine   = "lxc.cgroup2.cpu.max = ${toString cpuMaxQuota} ${toString wdCg.cpu_period_us}";
in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # WAYDROID (Android Container)
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # FIX: Don't auto-start container at boot to prevent GUI freezes.
  # The hwcomposer crash-loops every 5 seconds due to cgroup permission issues,
  # which creates resource contention that freezes KWin/Plasma.
  #
  # Start manually with: waydroid session start
  # Or select the "Android" session from SDDM login screen.
  #

  virtualisation.waydroid.enable = true;

  # ── Waydroid networking fix for nftables-only kernels (6.19+) ──────────────
  # waydroid-1.4.3's waydroid-net.sh hardcodes LXC_USE_NFT="false" → it prefers
  # the LEGACY iptables binary, which needs the `ip_tables` kernel module. The
  # linux-surface 6.19.8 kernel is nftables-only (no legacy ip_tables module), so
  # `waydroid session start` aborts at `waydroid-net.sh start` (RuntimeError) and
  # Waydroid won't boot. The script already has a full nftables path (start_nftables)
  # gated on LXC_USE_NFT="true" + `nft` on PATH — neither of which the package ships.
  # Patch its bundled net.sh to take that path. PROVEN: with both changes net.sh
  # brings waydroid0 (192.168.240.1/24) up on this kernel. Drop this override if a
  # future waydroid release auto-detects nftables.
  nixpkgs.overlays = [
    (final: prev: {
      waydroid = prev.waydroid.overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          substituteInPlace "$out/lib/waydroid/data/scripts/.waydroid-net.sh-wrapped" \
            --replace 'LXC_USE_NFT="false"' 'LXC_USE_NFT="true"
          export PATH="${final.nftables}/bin:$PATH"'

          # CPU cap: bound the Android LXC container's CPU bandwidth (cgroup2
          # cpu.max) so a runaway workload can never peg ALL logical CPUs and
          # freeze the host. Value is data-driven (waydroid.json). config_base is
          # cat'd verbatim into the generated LXC config on every session start
          # (tools/helpers/lxc.py), so the cap survives waydroid regeneration.
          echo '${cpuMaxLine}' >> "$out/lib/waydroid/data/configs/config_base"
        '';
      });
    })
  ];

  systemd.services.waydroid-container = {
    # Don't auto-start - only run when manually started
    wantedBy = lib.mkForce [];

    # When started, delegate cgroups properly to fix permission errors
    serviceConfig = {
      Delegate = "yes";
      KillMode = "mixed";
      TimeoutStopSec = 30;
    };
  };

  # ─── ARM translation (libhoudini) ──────────────────────────────────────────
  #
  # WHY: Host is x86_64; Waydroid runs an x86_64 Android image. The
  # cloud-superapp APK (~/git/unix/ea_cloud-superapp) is arm64-v8a ONLY and
  # carries MapLibre Native .so libs — it will not run without an ARM bridge.
  # libhoudini is Intel's translator (correct for this Intel CPU; libndk is the
  # AMD-leaning alternative).
  #
  # The bridge install mutates /var/lib/waydroid/overlay — root-owned RUNTIME
  # state created by `waydroid init`. It cannot be expressed purely
  # declaratively, so we DECLARE the tool (NUR waydroid-script) and wrap the
  # one-time install in a GUARDED, IDEMPOTENT oneshot (same pattern as
  # configuration_swapfile_resume_check.nix). The oneshot is triggered by the
  # `waydroid-launch` wrapper (configuration_packages.nix), not at boot — it is
  # a no-op once libhoudini.so is present.

  environment.systemPackages = [ nurpkgs.waydroid-script ];

  systemd.services.waydroid-arm-bootstrap = {
    description = "Install libhoudini ARM translation into Waydroid (one-time, idempotent)";
    # Triggered on demand by waydroid-launch; never auto-started at boot
    # (the install stops/restarts the container and mounts the overlay).
    wantedBy = lib.mkForce [];
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];

    # Skip entirely once the bridge lib is already in the overlay.
    unitConfig.ConditionPathExists =
      "!/var/lib/waydroid/overlay/system/lib64/libhoudini.so";

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 900;  # blob download + partition resize can be slow
    };
    path = with pkgs; [ nurpkgs.waydroid-script pkgs.waydroid coreutils util-linux ];
    script = ''
      set -u

      # The bridge can only be injected once the Android system image exists
      # (`sudo waydroid init` pulls it, ~1GB). If it's missing, fail LOUDLY and
      # NON-zero so the unit does not latch active — the next waydroid-launch
      # retries after the user has run init.
      if [ ! -d /var/lib/waydroid/images ] || [ ! -e /var/lib/waydroid/waydroid.cfg ]; then
        logger -t waydroid-arm-bootstrap -p user.err \
          "Waydroid not initialised — run 'sudo waydroid init' first, then re-launch."
        echo "[waydroid-arm-bootstrap] /var/lib/waydroid not initialised — run 'sudo waydroid init'." >&2
        exit 1
      fi

      echo "[waydroid-arm-bootstrap] installing libhoudini ARM translation…"
      waydroid-script install libhoudini
      echo "[waydroid-arm-bootstrap] libhoudini installed; ARM apps now runnable."
    '';
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # PODMAN + LIBVIRT (Data in @shared/data/containers/)
  # ═══════════════════════════════════════════════════════════════════════════

  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
    };

    libvirtd.enable = true;
  };

  virtualisation.containers.storage.settings = {
    storage = {
      driver = "btrfs";
      graphroot = "/mnt/shared/data/containers/podman";
    };
  };
}
