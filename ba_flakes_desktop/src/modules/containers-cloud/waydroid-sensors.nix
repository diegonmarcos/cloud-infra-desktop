# containers-cloud/waydroid-sensors.nix
#
# Run the IIO-backed Android sensors HAL (da_waydroid-sensors) as a user service
# so Waydroid gets a real accelerometer → auto-rotate works.
#
# Same idiom as containers-cloud/waydroid.nix (the superapp installer):
#   * The daemon + its conf are PRE-BUILT by the repo's universal engine
#     (`~/git/unix/da_waydroid-sensors/build.sh build` → dist/). This service
#     never builds — it runs the pre-built artifact. No cross-flake nix eval.
#   * Everything data-driven: the run-script reads da_waydroid-sensors/build.json
#     at RUNTIME (jq) for the binder device + boot-prop overrides — nothing
#     hardcoded here.
#
# Why a long-running Restart=always service (not the superapp's oneshot+timer):
# the HAL is a daemon, and it MUST be registered when the session's Android boots
# (so the framework binds it natively with stub_sensors_hal=0). The run-script
# therefore stays resident, waits for the binder node to appear (session start),
# then execs the daemon — which registers the moment the container's
# hwservicemanager comes up (gbinder presence handler), before SensorService
# init. The bounded poll() in SensorFW.cpp keeps that boot-safe.
#
# No root: we target /dev/hwbinder (world-rw; the system gbinder.d already maps
# it to the HIDL servicemanager), so this is purely user-level.
{ config, lib, ... }:

let
  binPath = "/run/current-system/sw/bin:${config.home.homeDirectory}/.nix-profile/bin:/etc/profiles/per-user/${config.home.username}/bin";
in
{
  home.file.".local/bin/waydroid-sensors-run" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Resident, idempotent. Waits for a Waydroid session's binder node, then
      # execs the HAL daemon. All facts come from build.json (data-driven).
      set -u
      export PATH="${binPath}:$PATH"

      command -v waydroid >/dev/null 2>&1 || { sleep 3600; exit 0; }   # waydroid not enabled
      command -v jq >/dev/null 2>&1 || exit 0

      SENSORS_DIR="$HOME/git/unix/da_waydroid-sensors"
      BJ="$SENSORS_DIR/build.json"
      [ -f "$BJ" ] || { sleep 3600; exit 0; }

      DEV="$(jq -r '.binder.device' "$BJ")"
      BIN="$SENSORS_DIR/dist/$(jq -r '.paths.binary' "$BJ")"
      CONF="$SENSORS_DIR/dist/$(basename "$(jq -r '.paths.conf' "$BJ")")"

      # Daemon must be built by the engine first; until then, do nothing (idle).
      if [ ! -x "$BIN" ] || [ ! -f "$CONF" ]; then
        echo "[waydroid-sensors] daemon/conf not built — run: (cd $SENSORS_DIR && ./build.sh build)"
        sleep 3600; exit 0
      fi

      # Boot-prop override (data-driven): the framework reads these AT container
      # boot. Setting stub_sensors_hal=0 makes SensorService load our HAL instead
      # of the empty stub. Written before the session boots (this runs at login).
      PROP_FILE="$HOME/.local/share/waydroid/waydroid_base.prop"
      mkdir -p "$(dirname "$PROP_FILE")"; touch "$PROP_FILE"
      jq -r '.waydroid.boot_props // {} | to_entries[] | "\(.key)=\(.value)"' "$BJ" | while IFS= read -r kv; do
        key="''${kv%%=*}"
        grep -v "^''${key}=" "$PROP_FILE" > "$PROP_FILE.tmp" 2>/dev/null || true
        printf '%s\n' "$kv" >> "$PROP_FILE.tmp"
        mv "$PROP_FILE.tmp" "$PROP_FILE"
      done

      # Supervise the daemon FRESH per container session. The upstream daemon
      # survives a service-manager death and tries to RECONNECT, but that
      # reconnect does NOT re-register ISensors on a NEW container's
      # hwservicemanager (verified: a daemon that persisted across a session
      # restart shows ISensors declared-but-not-served). So instead of exec'ing
      # the daemon once, we loop: start it when /dev/hwbinder appears, and kill it
      # when the node vanishes (session/container stop), so the NEXT session gets a
      # freshly-registering daemon that SensorService can bind at boot.
      cleanup() { [ -n "''${hal:-}" ] && kill "$hal" 2>/dev/null; }
      trap 'cleanup; exit 0' TERM INT
      while :; do
        while [ ! -e "$DEV" ]; do sleep 2; done
        echo "[waydroid-sensors] $DEV present — starting HAL ($BIN)"
        env WAYDROID_SENSORS_CONF="$CONF" "$BIN" "$DEV" &
        hal=$!
        while [ -e "$DEV" ] && kill -0 "$hal" 2>/dev/null; do sleep 2; done
        echo "[waydroid-sensors] $DEV gone or HAL exited — recycling for next session"
        kill "$hal" 2>/dev/null || true
        wait "$hal" 2>/dev/null || true
        hal=
      done
    '';
  };

  systemd.user.services.waydroid-sensors = {
    Unit = {
      Description = "Waydroid IIO sensors HAL (accelerometer → auto-rotate)";
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/.local/bin/waydroid-sensors-run";
      Restart = "always";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
