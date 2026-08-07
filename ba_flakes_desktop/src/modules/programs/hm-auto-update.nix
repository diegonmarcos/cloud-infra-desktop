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
  # the KB-sized digest/label inspect. hm-auto-update-check/-cancel are the
  # writeShellApplication-wrapped scripts above (their store paths land on
  # PATH as `hm-auto-update-check` / `hm-auto-update-cancel`, matching the
  # binary names the systemd user units below invoke).
  home.packages = [ pkgs.skopeo pkgs.yad hmAutoUpdateCheckPkg hmAutoUpdateCancelPkg ];

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
