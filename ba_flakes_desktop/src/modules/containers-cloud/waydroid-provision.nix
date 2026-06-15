# containers-cloud/waydroid-provision.nix
#
# DECLARATIVE self-healing of the Waydroid app/layout/theme provisioning.
#
# Why this exists: da_waydroid-apps applies its state (install APKs, seed the
# launcher dock/folders, dark mode + wallpaper) by mutating the RUNNING Waydroid
# container — that state lives in Waydroid's /data, which is NOT declarative and
# is lost on any /data reset or corruption (keystore/package-db corruption has
# wiped it repeatedly). The engine is the source of truth; this service makes the
# DEPLOYMENT declarative: whenever a Waydroid session is up and our apps aren't
# present, it re-runs the engine's provisioning. So a /data wipe/reboot self-heals
# — nothing is permanently lost.
#
# Same idiom as containers-cloud/waydroid.nix (superapp installer): a guarded,
# idempotent home.file script + a oneshot user service + a poll timer (the
# Waydroid session is started manually, so there is no user unit to order against).
# Fully data-driven: reads da_waydroid-apps/build.json at RUNTIME (jq) for the
# sentinel package; the APK set is pre-built by the engine (dist/apks, host-side,
# survives /data resets). No values hardcoded here.
{ config, lib, ... }:

let
  binPath = "/run/current-system/sw/bin:${config.home.homeDirectory}/.nix-profile/bin:/etc/profiles/per-user/${config.home.username}/bin";
in
{
  home.file.".local/bin/waydroid-provision" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Idempotent: exits 0 on every not-ready guard so the timer keeps polling
      # quietly. (Re)provisions only when a session is up + our apps are absent.
      set -u
      export PATH="${binPath}:$PATH"

      command -v waydroid >/dev/null 2>&1 || exit 0
      command -v jq >/dev/null 2>&1 || exit 0

      APPS_DIR="$HOME/git/unix/da_waydroid-apps"
      BJ="$APPS_DIR/build.json"
      [ -x "$APPS_DIR/build.sh" ] && [ -f "$BJ" ] || exit 0

      # Need a RUNNING, booted session.
      waydroid status 2>/dev/null | grep -q "Session.*RUNNING" || exit 0

      # The pinned/built APK set lives host-side (dist/apks) and survives /data
      # resets. If it was never built, point the operator at the engine and bail.
      if [ ! -d "$APPS_DIR/dist/apks" ]; then
        echo "[waydroid-provision] APK set not built — run once: (cd $APPS_DIR && ./build.sh build)"
        exit 0
      fi

      # Idempotency sentinel (data-driven): the first declared app. If it is
      # installed, the container is already provisioned for this /data → no-op.
      SENTINEL="$(jq -r '.apps[0].package' "$BJ")"
      if sudo waydroid shell -- pm path "$SENTINEL" >/dev/null 2>&1; then
        exit 0
      fi

      echo "[waydroid-provision] fresh/empty /data detected — re-provisioning from build.json…"
      "$APPS_DIR/build.sh" install
      "$APPS_DIR/build.sh" layout
      "$APPS_DIR/build.sh" theme
      echo "[waydroid-provision] done (apps + dock/folders + dark mode + wallpaper restored)."
    '';
  };

  systemd.user.services.waydroid-provision = {
    Unit.Description = "Self-healing Waydroid provisioning (apps + layout + theme) from da_waydroid-apps";
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/waydroid-provision";
    };
  };

  systemd.user.timers.waydroid-provision = {
    Unit.Description = "Poll for a Waydroid session and re-provision if /data was reset";
    Timer = {
      OnBootSec = "3min";
      OnUnitActiveSec = "3min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
