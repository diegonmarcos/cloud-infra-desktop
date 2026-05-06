# Fallback & safety: safe-graphics specialisation, KWin watchdog, GC protection
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # SDDM GREETER MODE — left to configuration_display.nix
  # ═══════════════════════════════════════════════════════════════════════════
  # The default greeter is Wayland (set in configuration_display.nix:
  # services.displayManager.sddm.wayland.enable = true).
  #
  # Why NOT force X11 greeter here:
  #   On Surface Pro 8 (Intel i915 + KMS), the SDDM X11 greeter acquires DRM
  #   master on vt2 and does NOT release it cleanly when sddm-helper jumps VT
  #   to start the Plasma Wayland session. The new kwin_wayland on the target
  #   VT then fails every drmModeAtomicCommit with EACCES, leaving the GUI
  #   permanently frozen. Reproduced 100% on 2026-04-28 (twice in one session).
  #   Evidence: journalctl shows `kwin_wayland_drm: atomic commit failed:
  #   Permission denied` + `[dix] couldn't enable device 11/12/13`.
  #
  # The genuine recovery path is the `safe-graphics` specialisation below
  # (full GNOME-on-X11 + GDM stack), selectable from GRUB. A half-X11/half-
  # Wayland greeter is not a fallback, it's a deadlock.

  # ═══════════════════════════════════════════════════════════════════════════
  # SAFE GRAPHICS — Fallback when Plasma/Wayland crashes
  # ═══════════════════════════════════════════════════════════════════════════
  # Appears in GRUB as "NixOS - Safe Graphics"
  # - Forces GNOME on X11 (no Wayland compositor to orphan DRM)
  # - Disables Plasma entirely (avoids KWin crash loop)
  # - TTYs always reachable (X11 doesn't hold DRM master exclusively)
  # - Uses modesetting driver (bypass i915-specific issues)
  specialisation.safe-graphics.configuration = {
    # Use GNOME on X11 (most reliable fallback)
    services.xserver.enable = lib.mkForce true;
    services.xserver.desktopManager.gnome.enable = lib.mkForce true;
    services.displayManager.sddm.enable = lib.mkForce false;
    services.xserver.displayManager.gdm.enable = lib.mkForce true;
    services.xserver.displayManager.gdm.wayland = lib.mkForce false;

    # Disable Plasma entirely (prevent KWin from starting)
    services.desktopManager.plasma6.enable = lib.mkForce false;

    # No plymouth (faster to diagnose)
    boot.plymouth.enable = lib.mkForce false;

    # Force basic modesetting driver (bypass i915 issues)
    services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # KWIN CRASH WATCHDOG — Release DRM master on repeated crashes
  # ═══════════════════════════════════════════════════════════════════════════
  # If KWin crashes 3+ times in 60 seconds, force VT switch to TTY2
  # so the user isn't stuck on a black screen with no TTY access.
  systemd.user.services."kwin-crash-watchdog" = {
    description = "KWin crash watchdog — switch to TTY on repeated crashes";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = 10;
      ExecStart = pkgs.writeShellScript "kwin-crash-watchdog" ''
        CRASH_COUNT=0
        WINDOW=60
        THRESHOLD=3
        LAST_RESET=$(date +%s)

        # Monitor KWin via systemd user journal
        ${pkgs.systemd}/bin/journalctl --user -u plasma-kwin_wayland -f --no-tail -o cat | while read -r line; do
          NOW=$(date +%s)

          # Reset counter if window expired
          if [ $((NOW - LAST_RESET)) -ge $WINDOW ]; then
            CRASH_COUNT=0
            LAST_RESET=$NOW
          fi

          # Detect crash indicators
          case "$line" in
            *"terminated"*|*"crash"*|*"SEGV"*|*"signal 11"*|*"Compositor crashed"*)
              CRASH_COUNT=$((CRASH_COUNT + 1))
              echo "[kwin-watchdog] KWin crash detected ($CRASH_COUNT/$THRESHOLD in ''${WINDOW}s window)"

              if [ $CRASH_COUNT -ge $THRESHOLD ]; then
                echo "[kwin-watchdog] THRESHOLD REACHED — switching to TTY2"
                ${pkgs.kbd}/bin/chvt 2 2>/dev/null || true
                CRASH_COUNT=0
                LAST_RESET=$NOW
              fi
              ;;
          esac
        done
      '';
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # GC GENERATION PROTECTION — Ensure GRUB rollback always works
  # ═══════════════════════════════════════════════════════════════════════════
  # Pin the last 3 system generations so they survive garbage collection.
  # Without this, aggressive GC can delete all rollback targets within a week.
  nix.gc.options = lib.mkForce "--delete-older-than 14d";
}
