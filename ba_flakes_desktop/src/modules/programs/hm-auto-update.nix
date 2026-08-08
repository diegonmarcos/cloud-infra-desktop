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
  # Still read at build time so the systemd-user-timer knobs below
  # (poll_interval_seconds, on_boot_delay_seconds) can stay Nix-side per the
  # inline-shell-scripts rule (those are build-time systemd unit values, not
  # runtime behaviour). Every value the SCRIPTS themselves need is read at
  # RUNTIME from the deployed JSON via jq — see hm-auto-update-check.sh /
  # hm-auto-update-cancel.sh.
  cfg = builtins.fromJSON (builtins.readFile ./hm-auto-update.json);

  hmAutoUpdateCheckPkg = pkgs.writeShellApplication {
    name = "hm-auto-update-check";
    runtimeInputs = with pkgs; [ jq skopeo yad gawk coreutils gh libnotify systemd ];
    text = builtins.readFile ./hm-auto-update-check.sh;
  };

  hmAutoUpdateCancelPkg = pkgs.writeShellApplication {
    name = "hm-auto-update-cancel";
    runtimeInputs = with pkgs; [ systemd ];
    text = builtins.readFile ./hm-auto-update-cancel.sh;
  };
in {
  # hm-auto-update-check.sh reads its config at RUNTIME from this path via
  # jq — this is the one place that declares it (HOME-MANAGER side, so
  # xdg.configFile, not environment.etc).
  xdg.configFile."cloud-data/hm-auto-update.json".source = ./hm-auto-update.json;

  # yad = the countdown dialog (same tool the pre-hibernate warning uses:
  # --timeout + --timeout-indicator give a visible auto-proceed bar). skopeo =
<<<<<<< Updated upstream
  # the KB-sized digest/label inspect. hm-auto-update-check/-cancel are the
  # writeShellApplication-wrapped scripts above (their store paths land on
  # PATH as `hm-auto-update-check` / `hm-auto-update-cancel`, matching the
  # binary names the systemd user units below invoke).
  home.packages = [ pkgs.skopeo pkgs.yad hmAutoUpdateCheckPkg hmAutoUpdateCancelPkg ];
||||||| Stash base
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
      MIN_FREE_MB="''${HAU_MIN_FREE_MB:-${toString sf.min_free_mb}}"
      SW_MEM_MAX="${sf.switch_memory_max}"
      SW_SWAP_MAX="${sf.switch_swap_max}"

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

      # ── RAM-headroom guard (2026-07-10) ─────────────────────────────────
      # A new generation exists — but if the desktop is already memory-full,
      # firing a ~GB pull now tips user-1000.slice into reclaim-thrash and
      # freezes the box (exactly the 13:41 bootstrap freeze). DEFER: do NOT
      # record the digest, so the very next poll retries once the box has
      # headroom. This is the difference between "auto-update waits politely"
      # and "auto-update freezes your desktop".
      AVAIL_MB=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
      AVAIL_MB="''${AVAIL_MB:-0}"
      if [ "$AVAIL_MB" -lt "$MIN_FREE_MB" ]; then
        echo "hm-auto-update: DEFERRING switch — only ''${AVAIL_MB}MB free < ''${MIN_FREE_MB}MB safe floor; will retry next poll (digest NOT recorded)" >&2
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

      echo "hm-auto-update: activating generation $SHORT via build.sh switch (bounded: mem<=$SW_MEM_MAX swap<=$SW_SWAP_MAX)" >&2
      # Detached — survives this oneshot service's own lifetime. build.sh's
      # own .switch.lock flock (cmd_switch_runner) makes this safe even if a
      # manual switch is already in flight. `switch` is incremental-first.
      # MEMORY-BOUNDED: the switch's own footprint (build.sh, zstd, nix-store
      # import) is capped so it can't pile onto the full desktop; if it
      # balloons, oomd/OOM sacrifices the SWITCH, never the compositor.
      systemd-run --user --unit=hm-auto-switch --collect \
        -p MemoryHigh="$SW_MEM_MAX" -p MemoryMax="$SW_MEM_MAX" -p MemorySwapMax="$SW_SWAP_MAX" \
        "$BUILD_SH" switch
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
=======
  # the KB-sized digest/label inspect. Both on PATH for the generated scripts.
  home.packages = [ pkgs.skopeo pkgs.yad ];

  home.file.".local/bin/hm-auto-update-check" = {
    executable = true;
    text = builtins.replaceStrings
      [ "@image@"      "@tag@"      "@repoBuildSh@"      "@delaySeconds@"            "@dialogCenter@"         "@notifySend@"            "@minFreeMb@"              "@switchMemoryMax@"         "@switchSwapMax@"         ]
      [ cfg.image      cfg.tag      cfg.repo_build_sh    (toString cd.delay_seconds)  (boolSh ch.dialog_center) (boolSh ch.notify_send)   (toString sf.min_free_mb)  sf.switch_memory_max        sf.switch_swap_max        ]
      (builtins.readFile ./scripts/hm-auto-update-check.sh);
  };

  # Mid-switch cancel: stop the detached switch unit (named in the notify text).
  home.file.".local/bin/hm-auto-update-cancel" = {
    executable = true;
    text = builtins.readFile ./scripts/hm-auto-update-cancel.sh;
  };
>>>>>>> Stashed changes

  systemd.user.services.hm-auto-update-check = {
    Unit = {
      Description = "Check GHCR for a new home-manager build";
      # graphical-session so DISPLAY/WAYLAND_DISPLAY are in scope for the yad
      # countdown dialog (falls back to headless-proceed if still absent).
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${hmAutoUpdateCheckPkg}/bin/hm-auto-update-check";
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
