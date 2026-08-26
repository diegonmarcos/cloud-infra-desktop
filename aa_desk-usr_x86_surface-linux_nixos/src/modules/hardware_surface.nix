# Surface Pro 8 hardware: kernel, CPU, firmware, power management
{ config, lib, pkgs, ... }:

let
  # surface-trackpad-watchdog: shell body lives in
  # ./surface-trackpad-watchdog.sh, data-driven at runtime from
  # /etc/cloud-data/surface-trackpad-watchdog.json (declared below).
  surfaceTrackpadWatchdog = pkgs.writeShellApplication {
    name = "surface-trackpad-watchdog";
    runtimeInputs = with pkgs; [ kmod coreutils procps gnugrep util-linux jq ];
    text = builtins.readFile ./surface-trackpad-watchdog.sh;
  };
in

{
  # Runtime data for surface-trackpad-watchdog (new cloud-data path —
  # verified against the already-declared environment.etc."cloud-data/..."
  # set, no collisions).
  environment.etc."cloud-data/surface-trackpad-watchdog.json".text =
    builtins.toJSON {
      interval_sec = 300;
      touchpad_name = "045E:09AF Touchpad";
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # LINUX-SURFACE KERNEL  ← ⚠ THIS IS THE ONLY LINE THAT TRIGGERS A REBUILD
  # ═══════════════════════════════════════════════════════════════════════════
  # CRITICAL: Surface Pro 8 Type Cover keyboard requires linux-surface kernel
  # (mainline kernel lacks surface_aggregator_hub module needed for SAM).
  #
  # WHAT THIS COSTS — read before touching:
  # The one line below (`kernelVersion = "stable"`) switches NixOS from the
  # default `linuxPackages` (PREBUILT, cache.nixos.org has the binary) to
  # `linuxPackages_surface` (linux-surface fork — NO public Nix binary cache
  # has our derivation hash). Result: every first install on a fresh @nixos
  # subvol rebuilds the kernel locally from source (~26 hours on this CPU,
  # documented in incident_2026-05-15_pool_hibernate_corruption.md).
  #
  # NOTHING ELSE IN OUR FLAKE REBUILDS THE KERNEL. Everything we set under
  # boot.kernelModules, boot.initrd.{available,early}Modules, kernelParams,
  # kernel.sysctl, etc. — those are RUNTIME directives, NOT compile-time.
  # They reference modules ALREADY shipped in linuxPackages_surface. The
  # binary doesn't care what we configure in those.
  #
  # SHORTCUTS THAT EXIST (verified 2026-05-16):
  #   - Debian/Kali users get the SAME upstream kernel as a PREBUILT .deb at
  #     pkg.surfacelinux.com — no compile. That's why Kali on this hardware
  #     boots in seconds with a working Type Cover.
  #   - To make NixOS use that prebuilt: would need to wrap the .deb as a
  #     Nix kernel package (real engineering, deferred).
  #   - To make subsequent NixOS rebuilds skip the build: ship-boot-cache
  #     workflow publishes our locally-built kernel to ghcr.io; future
  #     installs pull instead of compile (in flight).

  # ⚠ MINIMUM REQUIRED VERSION: linux-surface >= 6.17.13 — carries the
  # hid-surface BTN_0 fix that ends the Type Cover click-loss bug (see the
  # TRACKPAD CLICK WATCHDOG section below). nixos-hardware master packages
  # 6.18 (longterm) / 6.19 (stable); keep the nixos-hardware input fresh
  # (`./build.sh update nixos-hardware`).
  hardware.microsoft-surface = {
    # Use stable linux-surface kernel (latest patched release)
    # Options: "stable" (latest) or "longterm" (LTS, default)
    kernelVersion = "stable";
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # HARDWARE
  # ═══════════════════════════════════════════════════════════════════════════

  # Surface Pro 8 has Intel Tiger Lake
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware for WiFi, etc.
  hardware.enableRedistributableFirmware = true;

  # Power management - no CPU cap, full performance
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # Platform
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ═══════════════════════════════════════════════════════════════════════════
  # PEN STASH PROBE NOISE (linux-surface#1845) — COSMETIC, NOT THE CLICK BUG
  # ═══════════════════════════════════════════════════════════════════════════
  # SSAM device 01:15:02:02:00 is the "pen stash" slot (maintainer-confirmed
  # in #1845; node ssam_node_hid_kip_penstash in surface_aggregator_registry.c,
  # hard-coded for all KIP keyboards). The Type Cover has no pen stash, so the
  # surface_hid probe reads a 0-byte descriptor and fails with -71 (EPROTO)
  # once per enumeration. Keyboard (iid 1) and touchpad (iid 3) probe
  # independently — this error does NOT affect them and does NOT cause the
  # click freezes (see watchdog section below for the real cause).
  # A udev driver_override rule CANNOT suppress it: the kernel probes the
  # device before udev processes the add event (verified 2026-06-11 —
  # driver_override stayed empty while the probe failure still logged).
  # Upstream fix (probe returning -ENODEV) not merged yet. Ignore the line.

  # ═══════════════════════════════════════════════════════════════════════════
  # LIBINPUT QUIRK: Disable touch-jump detection on Surface Type Cover
  # ═══════════════════════════════════════════════════════════════════════════
  # libinput detects "touch jumps" on the Surface touchpad and discards events.
  # After too many discards, it rate-limits and drops ALL input including clicks.
  # Journal shows: "kernel bug: Touch jump detected and discarded"
  # This quirk raises the threshold so libinput stops falsely detecting jumps.
  # See: https://wayland.freedesktop.org/libinput/doc/latest/touchpad-jumping-cursors.html
  # ═══════════════════════════════════════════════════════════════════════════
  # XWAYLAND: Prevent Xwayland from grabbing the Surface touchpad
  # ═══════════════════════════════════════════════════════════════════════════
  # On Wayland, input is handled by KWin's compositor-level libinput.
  # But Xwayland also grabs physical input devices as X11 inputs, causing a
  # race condition where BTN_LEFT events get consumed by Xwayland instead of
  # reaching KWin. This makes clicks stop working intermittently.
  # Fix: tell X11 to ignore the Surface touchpad entirely.
  environment.etc."X11/xorg.conf.d/99-surface-touchpad-ignore.conf".text = ''
    Section "InputClass"
      Identifier "Ignore Surface Touchpad in Xwayland"
      MatchProduct "Microsoft Surface 045E:09AF Touchpad"
      Option "Ignore" "true"
    EndSection
  '';

  environment.etc."libinput/local-overrides.quirks".text = ''
    [Microsoft Surface Type Cover Touchpad]
    MatchUdevType=touchpad
    MatchVendor=0x045E
    MatchProduct=0x09AF
    AttrUseVelocityAveraging=1
  '';

  # ═══════════════════════════════════════════════════════════════════════════
  # TRACKPAD CLICK WATCHDOG — stopgap for kernels WITHOUT the BTN_0 fix
  # ═══════════════════════════════════════════════════════════════════════════
  # ROOT CAUSE (diagnosed 2026-06-11, upstream-confirmed): SAM firmware reports
  # the Type Cover FN key as phantom mouse button BTN_0 (key 256 — verified
  # present in the 045E:09AE keyboard's input capabilities on this machine).
  # BTN_0 gets stuck "pressed" and repeats every ~34 ms, which breaks click /
  # focus handling on KWin Wayland while cursor motion keeps working.
  # Upstream: linux-surface#1851 + #1719, fixed by the hid-surface driver
  # (PR #1870, merged 2025-12-31), shipped as 0016-hid-surface.patch in
  # linux-surface releases >= 6.17.13-2 and all 6.18.x / 6.19.x.
  #
  # Manual recovery on unfixed kernels: toggle the FN key (LED off) — instant,
  # no module reload needed (per #1719).
  #
  # This watchdog blind-resets the HID stack every 5 min to clear the stuck
  # BTN_0 state. It AUTO-DISABLES when the running kernel is >= 6.17.13
  # (hid-surface fix present in-kernel), so it vanishes with the kernel bump.
  systemd.services.surface-trackpad-watchdog = lib.mkIf
    (lib.versionOlder config.boot.kernelPackages.kernel.version "6.17.13") {
    description = "Surface trackpad click loss watchdog";
    after = [ "graphical.target" ];
    wantedBy = [ "graphical.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${surfaceTrackpadWatchdog}/bin/surface-trackpad-watchdog";
    };
  };

  # ── CPU CLOCK: stop thermald holding it at a quarter speed ────────────────
  #
  # nixos-hardware's microsoft-surface-pro-intel module ships thermald with a
  # config named "Surface Pro Intel Thermal Workaround" whose <Preference> is
  # QUIET — the most conservative setting it has.
  #
  # MEASURED on this machine, not assumed: eight busy loops, CPU verifiably 78%
  # busy, package temperature 39 °C, and every core pinned at EXACTLY 1000 MHz
  # against a 4400 MHz ceiling. A round number like that under load at 39 °C is
  # enforcement, not physics. The cooling device engaged was
  #
  #     TCC Offset   cur_state = 10 / 63
  #
  # which is thermald lowering the effective thermal ceiling by 10 °C, so the
  # chip throttles as though it were 10 °C hotter than it is. Every Processor
  # cooling device sat at 0, so nothing else was clamping — and it was not the
  # usual suspects either: scaling_max == cpuinfo_max == 4.4GHz, no_turbo = 0,
  # max_perf_pct = 100, PL1 35W / PL2 60W, zero entries in thermal_throttle,
  # and running on AC.
  #
  # Turning it off does NOT remove the chip's protection. PROCHOT and the
  # hardware TCC still cut in at Tjmax and intel_pstate still scales; thermald
  # is a POLICY daemon, not the safety mechanism. What is lost is a
  # conservative fan/temperature profile, which is the thing being rejected.
  services.thermald.enable = lib.mkForce false;

  # mkForce, not plain false: the hardware module sets it directly, and without
  # this the two definitions collide instead of one winning.
}
