# programs/hm-auto-update.nix — auto-detect + auto-activate new home-manager
# builds. GHA (ship_nix-flakes_desktop_hm.yaml) pushes a layered incremental
# closure image to GHCR on every push (hm-cache-image, consumed by build.sh's
# ghcr_incremental_switch → ghcr_pull_layered — only changed layers transfer,
# NO 6GB download). This module closes the loop on the DESKTOP side: a systemd
# user timer polls the GHCR registry directly for that image's digest (no
# ntfy/webhook — direct registry query) and, on change, pops a CANCELLABLE
# countdown, then launches `build.sh switch` detached via systemd-run (survives
# the triggering process/session dying — the safe-launch pattern documented
# after the 2026-07-08 HM activation incidents). The switch itself opens the
# nix-switch-progress Konsole window (verbosity/progress surface). All values
# data-driven from hm-auto-update.json — nothing hardcoded here. Always-on.
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./hm-auto-update.json);
  cd  = cfg.countdown;
  ch  = cd.channels;
  boolSh = b: if b then "1" else "0";
in {
  # yad = the countdown dialog (same tool the pre-hibernate warning uses:
  # --timeout + --timeout-indicator give a visible auto-proceed bar). skopeo =
  # the KB-sized digest/label inspect. Both on PATH for the generated scripts.
  home.packages = [ pkgs.skopeo pkgs.yad ];

  home.file.".local/bin/hm-auto-update-check" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/hm-auto-update.nix — do not edit by hand.
      set -uo pipefail

      # HAU_* env overrides let test-hm-auto-update.sh exercise this exact
      # generated script with stub gh/skopeo/yad/systemd-run + an isolated
      # state dir, instead of testing a hand-copied duplicate of the logic.
      IMAGE="''${HAU_IMAGE:-${cfg.image}}"
      TAG="''${HAU_TAG:-${cfg.tag}}"
      BUILD_SH="''${HAU_BUILD_SH:-${cfg.repo_build_sh}}"
      DELAY="''${HAU_DELAY:-${toString cd.delay_seconds}}"
      DIALOG_ENABLED="''${HAU_DIALOG:-${boolSh ch.dialog_center}}"
      NOTIFY_ENABLED="${boolSh ch.notify_send}"

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

      # Record the new digest NOW: whether the user proceeds or skips, we must
      # not re-prompt every poll for the SAME digest. A later, different digest
      # will prompt afresh.
      echo "$NEW_DIGEST" > "$DIGEST_FILE"
      SHORT="''${NEW_DIGEST#sha256:}"; SHORT="''${SHORT:0:12}"

      [ "$NOTIFY_ENABLED" = "1" ] && command -v notify-send >/dev/null 2>&1 && \
        notify-send -i software-update-available "Home-manager auto-update" \
          "New generation ($SHORT) — activating in ''${DELAY}s. To stop mid-switch: hm-auto-update-cancel" || true

      # ── Cancellable countdown gate ──────────────────────────────────────
      # yad with --timeout draws a visible shrinking bar and auto-exits (70)
      # when it lapses = "proceed by default". Buttons: Switch now (0) /
      # Skip this build (1). Only an explicit Skip aborts; timeout, close, or
      # "Switch now" all proceed (honours the fully-automatic intent, with an
      # explicit opt-out). Headless (no DISPLAY/WAYLAND, no yad, or dialog
      # disabled) proceeds after the countdown — NEVER blocks unattended.
      DECISION="proceed"
      if [ "$DIALOG_ENABLED" = "1" ] && command -v yad >/dev/null 2>&1 \
         && { [ -n "''${DISPLAY:-}" ] || [ -n "''${WAYLAND_DISPLAY:-}" ]; }; then
        # Hard backstop (DELAY+5) in case yad itself hangs; yad's own --timeout
        # drives the visible countdown and exits 70 when it lapses.
        timeout $((DELAY + 5)) \
          yad --title="Home-manager auto-update" --window-icon=software-update-available \
              --width=460 --center --on-top --borders=12 \
              --image=software-update-available \
              --text="<b>New home-manager generation available</b>\ndigest $SHORT\n\nActivating automatically in $DELAY second(s).\nThe switch runs incrementally (only changed layers) and\nshows a live progress window." \
              --timeout="$DELAY" --timeout-indicator=bottom \
              --button="Skip this build!process-stop:1" \
              --button="Switch now!system-software-update:0"
        rc=$?
        case "$rc" in
          1) DECISION="skip" ;;   # explicit Skip only
          *) DECISION="proceed" ;; # 0 (now), 70 (timeout), 252 (closed), etc.
        esac
      else
        echo "hm-auto-update: no graphical dialog (headless/disabled) — proceeding after ''${DELAY}s" >&2
        sleep "$DELAY"
      fi

      if [ "$DECISION" = "skip" ]; then
        echo "hm-auto-update: user skipped generation $SHORT (digest recorded; next change re-prompts)" >&2
        [ "$NOTIFY_ENABLED" = "1" ] && command -v notify-send >/dev/null 2>&1 && \
          notify-send -i process-stop "Home-manager auto-update" "Skipped generation $SHORT." || true
        exit 0
      fi

      echo "hm-auto-update: activating generation $SHORT via build.sh switch" >&2
      # Detached — survives this oneshot service's own lifetime. build.sh's
      # own .switch.lock flock (cmd_switch_runner) makes this safe even if a
      # manual switch is already in flight. `switch` is incremental-first.
      systemd-run --user --unit=hm-auto-switch --collect "$BUILD_SH" switch
    '';
  };

  # Mid-switch cancel: stop the detached switch unit (named in the notify text).
  home.file.".local/bin/hm-auto-update-cancel" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/hm-auto-update.nix — cancel an in-flight
      # auto-switch. The switch is a detached `systemd-run --user` unit named
      # hm-auto-switch; stopping it aborts the download/activation.
      exec systemctl --user stop hm-auto-switch
    '';
  };

  systemd.user.services.hm-auto-update-check = {
    Unit = {
      Description = "Check GHCR for a new home-manager build";
      # graphical-session so DISPLAY/WAYLAND_DISPLAY are in scope for the yad
      # countdown dialog (falls back to headless-proceed if still absent).
      After = [ "graphical-session.target" ];
    };
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
