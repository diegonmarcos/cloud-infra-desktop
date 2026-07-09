# programs/hm-auto-update.nix — auto-detect + auto-activate new home-manager
# builds. GHA (ship_nix-flakes_desktop_hm.yaml) already pushes a layered
# incremental closure image to GHCR on every push (hm-cache-image, consumed
# by build.sh's ghcr_pull_layered). This module closes the loop on the
# DESKTOP side: a systemd user timer polls the GHCR registry directly for
# that image's digest (no ntfy/webhook — direct registry query, per direct
# request) and, on change, launches `build.sh switch` fully automatically,
# detached via systemd-run so it survives the triggering process/session
# dying (same safe-launch pattern documented after the 2026-07-08 HM
# activation incidents). All values data-driven from hm-auto-update.json —
# nothing hardcoded here. Always-on (same pattern as programs/dev-shell.nix).
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./hm-auto-update.json);
in {
  home.packages = [ pkgs.skopeo ];

  home.file.".local/bin/hm-auto-update-check" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/hm-auto-update.nix — do not edit by hand.
      set -uo pipefail

      # HAU_* env overrides let test-hm-auto-update.sh exercise this exact
      # generated script with stub gh/skopeo/systemd-run + an isolated state
      # dir, instead of testing a hand-copied duplicate of the logic.
      IMAGE="''${HAU_IMAGE:-${cfg.image}}"
      TAG="''${HAU_TAG:-${cfg.tag}}"
      BUILD_SH="''${HAU_BUILD_SH:-${cfg.repo_build_sh}}"

      command -v skopeo >/dev/null 2>&1 || { echo "hm-auto-update: skopeo missing, skipping check" >&2; exit 0; }
      command -v gh >/dev/null 2>&1 || { echo "hm-auto-update: gh CLI missing, skipping check" >&2; exit 0; }

      STATE_DIR="''${HAU_STATE_DIR:-$HOME/.cache/hm-auto-update}"
      mkdir -p "$STATE_DIR"
      DIGEST_FILE="$STATE_DIR/last-digest"

      TOKEN="$(gh auth token 2>/dev/null)" || { echo "hm-auto-update: gh not authenticated, skipping check" >&2; exit 0; }

      NEW_DIGEST="$(skopeo inspect --format '{{.Digest}}' --creds "x:$TOKEN" "docker://$IMAGE:$TAG" 2>/dev/null)"
      if [ -z "$NEW_DIGEST" ]; then
        echo "hm-auto-update: could not inspect $IMAGE:$TAG (unavailable or not yet pushed), skipping check" >&2
        exit 0
      fi

      if [ ! -f "$DIGEST_FILE" ]; then
        # First run — seed the baseline, don't trigger a switch for a digest
        # that (for all we know) is already what's active.
        echo "$NEW_DIGEST" > "$DIGEST_FILE"
        echo "hm-auto-update: seeded baseline digest $NEW_DIGEST" >&2
        exit 0
      fi

      OLD_DIGEST="$(cat "$DIGEST_FILE" 2>/dev/null || true)"
      if [ "$NEW_DIGEST" = "$OLD_DIGEST" ]; then
        exit 0
      fi

      echo "$NEW_DIGEST" > "$DIGEST_FILE"
      command -v notify-send >/dev/null 2>&1 && notify-send -i software-update-available "Home-manager auto-update" "New generation detected — switching…" || true

      # Detached — survives this oneshot service's own lifetime. build.sh's
      # own .switch.lock flock (cmd_switch_runner) makes this safe even if a
      # manual switch is already in flight.
      systemd-run --user --unit=hm-auto-switch --collect "$BUILD_SH" switch
    '';
  };

  systemd.user.services.hm-auto-update-check = {
    Unit.Description = "Check GHCR for a new home-manager build";
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/hm-auto-update-check";
    };
  };

  systemd.user.timers.hm-auto-update-check = {
    Unit.Description = "Poll GHCR for a new home-manager build";
    Timer = {
      OnBootSec = "${toString cfg.on_boot_delay_seconds}s";
      OnUnitActiveSec = "${toString cfg.poll_interval_seconds}s";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
