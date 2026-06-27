# Bulletproof Waydroid launcher. Replaces the fragile `waydroid show-full-ui`
# desktop entry with `waydroid-launch`, which is safe to run from a SHELL or a
# DESKTOP click and self-heals the failure modes hit in practice:
#
#   1. Stale half-state: `Session: RUNNING` with no live container -> the stock
#      `waydroid first-launch` attaches to the dead session and silently does
#      nothing. We detect it and force a clean reset.
#   2. Wedged display/GPU (gralloc HAL stopped -> system_server crash -> forever
#      load): we WATCH the boot and RECYCLE the container up to max_recycles
#      times, then surface a clear message (reboot/relogin needed for the GPU).
#   3. Missing Wayland env when started from a shell: we discover the socket.
#   4. Keystore /data corruption: waydroid-data-heal.service (ordered Before the
#      container) runs first; a clean reset re-triggers it.
#
# All root ops use `sudo -n` against tight NOPASSWD rules (below) so a desktop
# click never hangs on a password prompt. Tunables: waydroid.json::launcher.
{ config, lib, pkgs, ... }:

let
  wd = builtins.fromJSON (builtins.readFile ./waydroid.json);
  l = wd.launcher;
  waydroidBin = "${pkgs.waydroid}/bin/waydroid";
  systemctlBin = "${pkgs.systemd}/bin/systemctl";

  waydroid-launch = pkgs.writeShellApplication {
    name = "waydroid-launch";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.libnotify ];
    text = ''
      set -u
      WAYDROID=${waydroidBin}
      SYSTEMCTL=${systemctlBin}
      # MUST be the setuid wrapper, never a nix-store sudo (which isn't setuid).
      SUDO=/run/wrappers/bin/sudo
      BOOT_TIMEOUT=${toString l.boot_timeout_s}
      POLL=${toString l.poll_interval_s}
      MAX_RECYCLES=${toString l.max_recycles}

      log(){ printf '[waydroid-launch] %s\n' "$*"; }
      rootctl(){ "$SUDO" -n "$@"; }   # NOPASSWD-backed; -n => never blocks on a prompt
      notify(){ notify-send -i waydroid -a "Waydroid" -t 8000 "Waydroid" "$1" 2>/dev/null || true; }

      # 1. Wayland env (a shell often lacks it)
      : "''${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"; export XDG_RUNTIME_DIR
      if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
        for s in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
          if [ -S "$s" ]; then WAYLAND_DISPLAY="$(basename "$s")"; export WAYLAND_DISPLAY; break; fi
        done
      fi
      [ -n "''${WAYLAND_DISPLAY:-}" ] || log "WARN: no Wayland socket in $XDG_RUNTIME_DIR — a graphical session is required for the display"

      container_running(){ "$WAYDROID" status 2>/dev/null | grep -q 'Container.*RUNNING'; }
      session_running(){ "$WAYDROID" status 2>/dev/null | grep -q 'Session.*RUNNING'; }
      android_up(){
        [ "$(rootctl "$WAYDROID" shell -- getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] &&
        [ "$(rootctl "$WAYDROID" shell -- getprop init.svc.system_server 2>/dev/null | tr -d '\r')" = "running" ]
      }
      reset_clean(){
        log "clean reset (clears stale session + re-triggers keystore self-heal)…"
        "$WAYDROID" session stop >/dev/null 2>&1 || true
        rootctl "$WAYDROID" container stop >/dev/null 2>&1 || true
        rootctl "$SYSTEMCTL" restart waydroid-container.service >/dev/null 2>&1 || true
        sleep 2
      }

      # 2. ARM translation bootstrap (idempotent, best-effort)
      rootctl "$SYSTEMCTL" start waydroid-arm-bootstrap.service >/dev/null 2>&1 || true

      # 3. up-front stale/wedged-state reset (the "shortcut does nothing" bug)
      if session_running && ! container_running; then
        log "stale session with no container — resetting"
        notify "Resetting Android state… (~30 s)"
        reset_clean
      fi

      # 4. ensure the container is up (pulls in waydroid-data-heal Before it)
      if ! container_running; then
        notify "Starting Android container… (~30–60 s)"
        rootctl "$SYSTEMCTL" start waydroid-container.service >/dev/null 2>&1 || true
        sleep 2
      fi

      # 5. start the session if needed + announce to user only on cold boot
      if ! session_running; then
        android_up || notify "Booting Android… please wait (~30–60 s)"
        "$WAYDROID" session start >/dev/null 2>&1 & sleep 3
      fi

      # 6. boot watchdog + recycle fallback
      recycles=0
      while :; do
        waited=0
        while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
          if android_up; then
            log "Android up — opening UI"
            "$WAYDROID" show-full-ui
            log "UI closed — stopping container"
            "$WAYDROID" session stop >/dev/null 2>&1 || true
            rootctl "$SYSTEMCTL" stop waydroid-container.service >/dev/null 2>&1 || true
            exit 0
          fi
          sleep "$POLL"; waited=$((waited + POLL))
        done
        recycles=$((recycles + 1))
        if [ "$recycles" -gt "$MAX_RECYCLES" ]; then
          log "Android did not boot after $MAX_RECYCLES recycles — the display/GPU (gralloc) is wedged. Log out/in of the desktop or reboot to reset the graphics state, then relaunch."
          notify-send -i waydroid -a "Waydroid" -u critical "Waydroid — GPU wedged" "Android failed to boot. Log out/in or reboot, then try again." 2>/dev/null || true
          "$WAYDROID" show-full-ui   # last-ditch surface
          "$WAYDROID" session stop >/dev/null 2>&1 || true
          rootctl "$SYSTEMCTL" stop waydroid-container.service >/dev/null 2>&1 || true
          exit 1
        fi
        log "boot timeout (''${BOOT_TIMEOUT}s) — recycle ''${recycles}/''${MAX_RECYCLES}"
        notify "Android boot timed out — recycling (''${recycles}/''${MAX_RECYCLES})…"
        reset_clean
        "$WAYDROID" session start >/dev/null 2>&1 & sleep 3
      done
    '';
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "Waydroid";
    desktopName = "Waydroid";
    comment = "Android (self-healing launcher)";
    exec = "${waydroid-launch}/bin/waydroid-launch";
    icon = "waydroid";
    categories = [ "System" ];
    terminal = false;
  };

in {
  environment.systemPackages = [ waydroid-launch desktopItem ];

  # Tight NOPASSWD for exactly the root ops the launcher needs (so a desktop
  # click never prompts). getprop is read-only; container stop/start/restart +
  # arm-bootstrap are the lifecycle. Nothing else.
  security.sudo.extraRules = [{
    users = [ "diego" ];
    runAs = "root";
    commands = [
      { command = "${systemctlBin} start waydroid-arm-bootstrap.service"; options = [ "NOPASSWD" ]; }
      { command = "${systemctlBin} start waydroid-container.service"; options = [ "NOPASSWD" ]; }
      { command = "${systemctlBin} stop waydroid-container.service"; options = [ "NOPASSWD" ]; }
      { command = "${systemctlBin} restart waydroid-container.service"; options = [ "NOPASSWD" ]; }
      { command = "${waydroidBin} container stop"; options = [ "NOPASSWD" ]; }
      { command = "${waydroidBin} shell -- getprop *"; options = [ "NOPASSWD" ]; }
    ];
  }];
}
