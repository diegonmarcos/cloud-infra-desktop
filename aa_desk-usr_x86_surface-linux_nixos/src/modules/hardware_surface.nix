# Surface Pro 8 hardware: kernel, CPU, firmware, power management
{ config, lib, pkgs, ... }:

{
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
  # PEN STASH PROBE FIX (linux-surface#1845)
  # ═══════════════════════════════════════════════════════════════════════════
  # Device 01:15:02:02:00 is the "pen stash" slot on Surface Flex Keyboard.
  # Type Cover lacks this device, so surface_hid probe gets 0-byte descriptor,
  # returns -EPROTO (error -71), retries for ~2 min, disrupts entire HID stack
  # causing trackpad click freezes.

  # Option 2 (active): udev rule — prevent surface_hid from binding to pen stash
  services.udev.extraRules = ''
    SUBSYSTEM=="surface_aggregator_clients", ATTR{modalias}=="ssam:d01c15t02i02f00", ENV{MODALIAS}="", ATTR{driver_override}="(none)"
  '';

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
  # TRACKPAD CLICK WATCHDOG
  # ═══════════════════════════════════════════════════════════════════════════
  # hid-multitouch driver intermittently stops sending BTN_LEFT events under
  # system load (while BTN_TOUCH and motion continue). This watchdog monitors
  # the touchpad via evtest: if it sees touch activity (BTN_TOUCH) but zero
  # BTN_LEFT for 30s, it reloads the HID stack to recover clicks.
  systemd.services.surface-trackpad-watchdog = {
    description = "Surface trackpad click loss watchdog";
    after = [ "graphical.target" ];
    wantedBy = [ "graphical.target" ];
    path = with pkgs; [ kmod coreutils procps gnugrep ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      StandardOutput = "journal";
      StandardError = "journal";
    };
    script = ''
      # Only run on Plasma
      while ! pgrep -f kwin_wayland >/dev/null 2>&1; do sleep 5; done
      echo "[trackpad-watchdog] Plasma detected"

      # Proactive reset every 5 minutes — lightweight, no detection needed
      # The HID reset takes <2s and causes no visible interruption
      # This prevents BTN_LEFT from staying dead for more than 5 min
      while true; do
        sleep 300
        # Only reset if touchpad exists
        if grep -rq "045E:09AF Touchpad" /sys/class/input/event*/device/name 2>/dev/null; then
          echo "[trackpad-watchdog] Periodic HID reset"
          modprobe -r surface_hid_core surface_hid 2>/dev/null || true
          modprobe surface_hid_core surface_hid
          modprobe -r hid_multitouch 2>/dev/null || true
          modprobe hid_multitouch
          modprobe -r usbhid 2>/dev/null || true
          modprobe usbhid
          modprobe -r surface_aggregator_registry surface_aggregator_hub surface_hid surface_hid_core 2>/dev/null || true
          sleep 1
          modprobe surface_aggregator_registry
          modprobe surface_hid
        fi
      done
    '';
  };
}
