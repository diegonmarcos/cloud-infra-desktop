# programs/nix-switch-progress.nix — installs `nix-switch-progress-wrap`, a
# transparent wrapper that shows a KDE (kdialog) progress dialog with a REAL
# percentage for any nix command it wraps, driven by nix-switch-progress.mjs
# parsing `--log-format internal-json` build/copy activity events.
#
# Was designed (nix-switch-progress.mjs + .json, 2026-06-20) but never wired
# into home-manager — this file is that missing wiring. Always-on (same
# pattern as programs/dev-shell.nix): every profile gets the wrapper, since
# it applies to whichever nix command build.sh happens to run, not to any
# one leaf/profile.
#
# Contract (see nix-switch-progress.mjs's own header comment for the full
# activity-event parsing rationale): over SSH/TTY or with kdialog absent,
# the wrapper execs the command UNCHANGED — no window, no behavior change.
# All labels/icon/cap-% are data-driven from nix-switch-progress.json, never
# hardcoded in this file or the .mjs.
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./nix-switch-progress.json);
  mjs = ./nix-switch-progress.mjs;
in {
  home.file.".local/bin/nix-switch-progress-wrap" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/nix-switch-progress.nix — do not edit by hand.
      set -uo pipefail

      # Passthrough (no popup) when there's no graphical session or kdialog
      # is missing — this must never block a headless/CI/SSH nix invocation.
      if { [ -z "''${DISPLAY:-}" ] && [ -z "''${WAYLAND_DISPLAY:-}" ]; } || ! command -v kdialog >/dev/null 2>&1; then
        exec "$@"
      fi

      NSP_QDBUS="$(command -v qdbus 2>/dev/null || command -v qdbus6 2>/dev/null || echo qdbus)"
      export NSP_QDBUS
      export NSP_CAP="${toString cfg.cap_pct_until_done}"

      # `kdialog --progressbar <label> <max>` prints "service /Path" on stdout —
      # the D-Bus reference the .mjs script drives via qdbus Set/setLabelText.
      _ref="$(kdialog --title "${cfg.title}" --icon "${cfg.icon}" --progressbar "${cfg.initial_label}" ${toString cfg.max} 2>/dev/null)"
      NSP_SVC="$(awk '{print $1}' <<<"$_ref")"
      NSP_PATH="$(awk '{print $2}' <<<"$_ref")"
      export NSP_SVC NSP_PATH

      _close_dialog() {
        [ -n "$NSP_SVC" ] && "$NSP_QDBUS" "$NSP_SVC" "$NSP_PATH" close >/dev/null 2>&1 || true
      }
      trap _close_dialog EXIT

      # --log-format internal-json is a common nix arg, forwarded through by
      # both `nix build ...` and `home-manager switch ...` (which wraps nix
      # build internally) — trailing here is safe for either caller shape.
      # nix-switch-progress.mjs only DRIVES the dialog — it never re-emits
      # the lines it reads — so an optional NSP_LOG_FILE tee sits BEFORE it
      # in the pipe, preserving the caller's own log capture (build.sh sets
      # this to its own $LOG_FILE rather than teeing a second time itself).
      set -o pipefail
      if [ -n "''${NSP_LOG_FILE:-}" ]; then
        "$@" --log-format internal-json 2>&1 | tee -a "$NSP_LOG_FILE" | node "${mjs}"
      else
        "$@" --log-format internal-json 2>&1 | node "${mjs}"
      fi
      _rc=''${PIPESTATUS[0]}

      ${lib.optionalString cfg.notify_on_finish ''
      if command -v notify-send >/dev/null 2>&1; then
        if [ "$_rc" -eq 0 ]; then
          notify-send -i "${cfg.icon}" "${cfg.title}" "Completed successfully."
        else
          notify-send -u critical -i "${cfg.icon}" "${cfg.title}" "Failed (exit $_rc) — check the log."
        fi
      fi
      ''}

      exit "$_rc"
    '';
  };
}
