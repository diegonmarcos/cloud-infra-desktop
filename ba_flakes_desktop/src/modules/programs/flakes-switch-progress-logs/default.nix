# programs/flakes-switch-progress-logs/default.nix — installs
# `flakes-switch-progress-logs` (canonical name) and its compat alias
# `nix-switch-progress-wrap`, a transparent wrapper around any nix command
# build.sh runs. Shows exactly ONE window: a Konsole tailing a live,
# ANSI-colored, fully copyable status log — repo clean/dirty check, commit
# being applied vs the previously applied one (+ diffstat), closure size, a
# live PSI (/proc/pressure) panel with a spinner, a data-dense two-bar
# progress line (overall % + current-step %, byte sizes, elapsed/remaining/
# total ETA — see progress.mjs), and the real build/activation output —
# split into three self-detected phases (Preparing / Building & Copying /
# Activating), so `activate` is always its own visible step regardless of
# whether build.sh did a full local eval+build or a `pull` (fetch + activate
# only).
#
# The Konsole window is NEVER auto-closed — on success/failure it gets a
# final banner in the log plus a non-blocking notify-send toast; on failure
# the full (de-ANSI'd) log is copied to the clipboard automatically. Nothing
# blocks waiting for user interaction.
#
# History: designed as nix-switch-progress.mjs + .json (2026-06-20), enriched
# 2026-07-04, then collapsed from three windows (2 kdialog progress bars +
# Konsole) down to this single Konsole window per direct request — the two
# kdialog bars were data-poor (bare % + one-line label) versus the rich data
# already flowing through the Konsole log, so the fix was to put ALL progress
# data (both bars, sizes, ETA) into that one log stream instead of splitting
# it across three separate windows. Moved into this directory and renamed
# nix-switch-progress-wrap -> flakes-switch-progress-logs (2026-08-02) when
# build.sh grew a global re-exec that wraps EVERY invocation (not just the
# nix/home-manager calls this originally targeted) — see the owner/nested
# split below, and the compat alias's own comment for why the old name is
# still installed too.
# Always-on (same pattern as programs/dev-shell.nix). All labels/colors/
# spinner frames/refresh interval are data-driven from config.json —
# nothing hardcoded here or in progress.mjs. Passthrough (no window at all)
# when there's no graphical session or konsole is missing — must never
# block a headless/CI/SSH nix invocation.
{ config, pkgs, lib, ... }:
let
  # Runtime JSON (fire-rule 4 + 6): title/icon/notify_on_finish/
  # cap_pct_until_done/psi_refresh_seconds/spinner_frames/konsole_geometry/
  # colors are still authored here in config.json, but the extracted
  # flakes-switch-progress-logs.sh consumes them via a runtime jq read of
  # the deployed copy below — never Nix-interpolated into the script body.
  mjs = ./progress.mjs;

  wrapperPkg = pkgs.writeShellApplication {
    name = "flakes-switch-progress-logs";
    runtimeInputs = [ pkgs.jq pkgs.nodejs pkgs.git pkgs.gawk pkgs.gnused pkgs.coreutils ];
    runtimeEnv = {
      NSP_MJS_BIN = "${mjs}";
    };
    text = builtins.readFile ./flakes-switch-progress-logs.sh;
  };
in {
  # ── Runtime JSON deploy (Home Manager: xdg.configFile) ─────────────────
  xdg.configFile."cloud-data/flakes-switch-progress-logs.json".source = ./config.json;

  # Bound once, installed under BOTH names below — identical binary, so the
  # two entry points can never drift out of sync with each other.
  home.file.".local/bin/flakes-switch-progress-logs".source =
    "${wrapperPkg}/bin/flakes-switch-progress-logs";

  # Compat alias — NOT optional, do not drop. aa_desk-usr_x86_surface-linux_
  # nixos's src/modules/configuration_nix-command-catcher.nix (a NixOS SYSTEM
  # module in a DIFFERENT repo) PATH-shims `nix`/`nixos-rebuild` through the
  # wrapper by this EXACT name. Removing this file would silently degrade
  # that shim to plain passthrough until a full NixOS rebuild picks up a
  # renamed reference there too.
  home.file.".local/bin/nix-switch-progress-wrap".source =
    "${wrapperPkg}/bin/flakes-switch-progress-logs";
}
