# Surface Pro 8 hardware: kernel, CPU, firmware, power management
{ config, lib, pkgs, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # LINUX-SURFACE KERNEL
  # ═══════════════════════════════════════════════════════════════════════════
  # CRITICAL: Surface Pro 8 Type Cover keyboard requires linux-surface kernel
  # The mainline kernel lacks surface_aggregator_hub module needed for SAM

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
    path = with pkgs; [ kmod coreutils gnugrep gawk evtest ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
    };
    script = ''
      #!/bin/bash
      # Only run on Plasma (KWin) — GNOME doesn't trigger this bug
      if ! pgrep -x kwin_wayland >/dev/null 2>&1; then
        echo "[trackpad-watchdog] Not Plasma session, exiting"
        # Wait for Plasma to maybe start, then check again
        while ! pgrep -x kwin_wayland >/dev/null 2>&1; do
          sleep 30
        done
      fi
      echo "[trackpad-watchdog] Plasma detected, starting"

      find_touchpad() {
        for f in /sys/class/input/event*/device/name; do
          if grep -q "045E:09AF Touchpad" "$f" 2>/dev/null; then
            echo "/dev/input/$(echo "$f" | grep -oP 'event\d+')"
            return
          fi
        done
      }

      reset_hid() {
        echo "[trackpad-watchdog] BTN_LEFT lost — resetting HID stack"
        modprobe -r surface_hid_core surface_hid 2>/dev/null || true
        modprobe surface_hid_core surface_hid
        modprobe -r hid_multitouch
        modprobe hid_multitouch
      }

      while true; do
        TOUCHPAD=$(find_touchpad)
        if [ -z "$TOUCHPAD" ]; then
          sleep 5
          continue
        fi

        echo "[trackpad-watchdog] Monitoring $TOUCHPAD"

        # Sample 3 seconds of events
        EVENTS=$(timeout 3 evtest "$TOUCHPAD" 2>/dev/null || true)
        TOUCHES=$(echo "$EVENTS" | grep -c "BTN_TOUCH.*value 1" || true)
        CLICKS=$(echo "$EVENTS" | grep -c "BTN_LEFT.*value 1" || true)

        if [ "$TOUCHES" -ge 3 ] && [ "$CLICKS" -eq 0 ]; then
          echo "[trackpad-watchdog] Dead: $TOUCHES touches, 0 clicks in 3s"
          reset_hid
          sleep 5
        else
          sleep 1
        fi
      done
    '';
  };
}
