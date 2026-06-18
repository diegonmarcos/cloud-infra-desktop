# containers-cloud/waydroid-sensors-watchdog.nix
#
# Boot-safety watchdog for the Waydroid sensors HAL. WATCHDOG ONLY — it does NOT
# launch the daemon (waydroid's own container_manager.py does that at container
# start, via `which waydroid-sensord`). This service exists solely to GUARANTEE
# the Android container boots even when the real IIO sensors HAL fails to register
# on the container's hwservicemanager in time (the unresolved "declared-but-not-
# served" race: SensorService blocks in getService() for ISensors → sensorservice
# never publishes → boot hangs forever on the boot animation).
#
# Policy (data-driven from da_waydroid-sensors/build.json): per session, wait up to
# timeouts.boot_watchdog_s for the boot gate (sys.boot_completed=1). If it is not
# reached, the real-HAL path is wedged → force the in-container STUB sensors HAL
# (stub_prop=1, live setprop) and restart the framework so Android boots WITHOUT
# our HAL — stable, just no auto-rotate. The next container start re-probes the
# real HAL (the stub flip is per-session, never sticky), so auto-rotate returns
# automatically whenever the real HAL happens to register cleanly.
#
# This restores the fallback that used to live in the (removed) combined
# waydroid-sensors HM service; the daemon launch is now container_manager's job.
{ config, lib, ... }:

let
  binPath = "/run/current-system/sw/bin:${config.home.homeDirectory}/.nix-profile/bin:/etc/profiles/per-user/${config.home.username}/bin";
in
{
  home.file.".local/bin/waydroid-sensors-watchdog" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Resident, idempotent. Guarantees Waydroid boots: falls back to the stub
      # sensors HAL if the real HAL wedges the boot. All facts from build.json.
      set -u
      export PATH="${binPath}:$PATH"

      command -v waydroid >/dev/null 2>&1 || { sleep 3600; exit 0; }   # waydroid not enabled
      command -v jq >/dev/null 2>&1 || exit 0

      BJ="$HOME/git/unix/da_waydroid-sensors/build.json"
      [ -f "$BJ" ] || { sleep 3600; exit 0; }

      DEV="$(jq -r '.binder.device' "$BJ")"
      WATCHDOG_S="$(jq -r '.timeouts.boot_watchdog_s // 60' "$BJ")"
      FW_SETTLE_S="$(jq -r '.timeouts.framework_restart_settle_s // 5' "$BJ")"
      BOOT_GATE="$(jq -r '.waydroid.boot_gate_prop // "sys.boot_completed"' "$BJ")"
      STUB_PROP="$(jq -r '.waydroid.stub_prop // "waydroid.stub_sensors_hal"' "$BJ")"
      FW_RESTART="$(jq -r '.waydroid.framework_restart // "stop; sleep 1; start"' "$BJ")"

      boot_done() { [ "$(waydroid shell -- getprop "$BOOT_GATE" 2>/dev/null | tr -d '\r')" = "1" ]; }

      fallback_to_stub() {
        echo "[waydroid-watchdog] FALLBACK: '$BOOT_GATE' != 1 within ''${WATCHDOG_S}s — forcing STUB sensors HAL ($STUB_PROP=1) + restarting framework so Android boots (auto-rotate OFF this session; next session retries the real HAL)." >&2
        waydroid shell -- setprop "$STUB_PROP" 1 2>/dev/null || true
        waydroid shell -- sh -c "$FW_RESTART" 2>/dev/null || true
        sleep "$FW_SETTLE_S"
      }

      # Per-session watchdog: wait for a session (binder node), then give the boot
      # WATCHDOG_S to reach the gate; otherwise fall back to the stub. Then idle
      # until the session ends before watching the next one.
      while :; do
        while [ ! -e "$DEV" ]; do sleep 3; done
        waited=0; ok=0
        while [ "$waited" -lt "$WATCHDOG_S" ]; do
          [ -e "$DEV" ] || break
          if boot_done; then echo "[waydroid-watchdog] boot gate reached ($BOOT_GATE=1) — real HAL path OK"; ok=1; break; fi
          sleep 3; waited=$((waited+3))
        done
        [ "$ok" -eq 0 ] && [ -e "$DEV" ] && fallback_to_stub
        while [ -e "$DEV" ]; do sleep 5; done
      done
    '';
  };

  systemd.user.services.waydroid-sensors-watchdog = {
    Unit = {
      Description = "Waydroid boot-safety watchdog (fall back to stub sensors HAL if boot stalls)";
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/.local/bin/waydroid-sensors-watchdog";
      Restart = "always";
      RestartSec = 10;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
