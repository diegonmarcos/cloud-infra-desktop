# containers-cloud/waydroid.nix
#
# Auto-install the cloud-superapp APK into a running Waydroid session.
#
# Waydroid itself + the libhoudini ARM bridge are SYSTEM-level concerns owned by
# the NixOS host flake (aa_desk-usr_x86_surface-linux_nixos:
# configuration_containers.nix) — they write the root-owned /var/lib/waydroid
# overlay, which a user service cannot touch. This module owns only the
# user-session piece: a guarded, idempotent poller that installs the built APK
# once a session is up.
#
# Data-driven: the script reads ~/git/unix/ea_cloud-superapp/build.json at
# RUNTIME (jq) for the application_id + artifact name — no values hardcoded
# here, and no cross-flake nix eval. The APK is produced by that repo's
# universal engine (`build.sh build` / `build.sh waydroid-install`); this
# service never builds, it only installs a pre-built APK.
#
# Why a timer (not an After= hook): the Waydroid session is started manually
# (host config keeps it off at boot), so there is no user unit to order against.
# A low-overhead guarded timer is the repo idiom (cf. ssh-stale-socket-cleaner).
{ config, lib, ... }:

let
  appId = "com.diegonmarcos.superapp";           # display/log label only; truth is build.json
  # System waydroid + user-profile jq must both be reachable from the minimal
  # user-service PATH.
  binPath = "/run/current-system/sw/bin:${config.home.homeDirectory}/.nix-profile/bin:/etc/profiles/per-user/${config.home.username}/bin";
in
{
  home.file.".local/bin/waydroid-superapp-install" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Idempotent: every guard that isn't ready exits 0 so the timer keeps
      # polling quietly. Installs only when session up + APK built + not present.
      set -u
      export PATH="${binPath}:$PATH"

      command -v waydroid >/dev/null 2>&1 || exit 0   # waydroid not enabled

      SUPERAPP_DIR="$HOME/git/unix/ea_cloud-superapp"
      BJ="$SUPERAPP_DIR/build.json"
      [ -f "$BJ" ] || exit 0

      APP_ID="$(jq -r '.android.application_id' "$BJ")"
      ARTIFACT="$(jq -r '.release.artifact.debug' "$BJ")"
      APK="$SUPERAPP_DIR/dist/$ARTIFACT"

      # Need a RUNNING session for `waydroid app install`.
      waydroid status 2>/dev/null | grep -q "Session.*RUNNING" || exit 0

      if [ ! -f "$APK" ]; then
        echo "[waydroid-superapp] APK not built yet ($APK) — run: (cd $SUPERAPP_DIR && ./build.sh build)"
        exit 0
      fi

      # Already installed → nothing to do.
      if waydroid app list 2>/dev/null | grep -q "$APP_ID"; then
        exit 0
      fi

      echo "[waydroid-superapp] installing $APK into Waydroid ($APP_ID)"
      waydroid app install "$APK"
    '';
  };

  # Convenience: ensure install, bring up a session via the host launcher, then
  # foreground the app. (waydroid-launch is provided by the NixOS host flake.)
  home.file.".local/bin/superapp-launch" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -u
      export PATH="${binPath}:$PATH"
      command -v waydroid >/dev/null 2>&1 || { echo "waydroid not enabled on this host"; exit 1; }

      APP_ID="${appId}"
      if command -v jq >/dev/null 2>&1 && [ -f "$HOME/git/unix/ea_cloud-superapp/build.json" ]; then
        APP_ID="$(jq -r '.android.application_id' "$HOME/git/unix/ea_cloud-superapp/build.json")"
      fi

      if ! waydroid status 2>/dev/null | grep -q "Session.*RUNNING"; then
        command -v waydroid-launch >/dev/null 2>&1 && waydroid-launch &
        for _ in $(seq 1 20); do
          waydroid status 2>/dev/null | grep -q "Session.*RUNNING" && break
          sleep 1
        done
      fi

      "$HOME/.local/bin/waydroid-superapp-install" || true
      waydroid app launch "$APP_ID"
    '';
  };

  systemd.user.services.waydroid-superapp-install = {
    Unit.Description = "Auto-install cloud-superapp APK into a running Waydroid session";
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/waydroid-superapp-install";
    };
  };

  systemd.user.timers.waydroid-superapp-install = {
    Unit.Description = "Poll for a Waydroid session and install cloud-superapp once";
    Timer = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
