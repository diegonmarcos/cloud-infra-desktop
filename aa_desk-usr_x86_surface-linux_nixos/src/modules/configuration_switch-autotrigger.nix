# POST-2026-07-22: switch-autotrigger — when CI publishes a new system closure
# it POSTs "closure-ready <sha>" to the ntfy topic below; this user service
# subscribes (SSE /raw) and AUTO-RUNS `build.sh switch`. The switch itself then
# fires the full messaging stack: notify-send start alert, konsole byte-log,
# TUI dashboard, KDE popup dashboard, per-stage alerts, done/fail alert.
# Data-driven from cloud-data-nix-build.json .autotrigger {enable,url,topic,repo}.
{ config, pkgs, lib, ... }:
let
  data = builtins.fromJSON (builtins.readFile ./cloud-data-nix-build.json);
  cfg = data.autotrigger or { enable = false; };
  listener = pkgs.writeShellScript "nixos-switch-autotrigger" ''
    # ponytail: plain curl SSE poll loop; reconnects every drop, 10s backoff
    while :; do
      ${pkgs.curl}/bin/curl -sN --max-time 3600 "${cfg.url}/${cfg.topic}/raw" 2>/dev/null \
      | while IFS= read -r line; do
          case "$line" in
            *closure-ready*)
              ${pkgs.libnotify}/bin/notify-send -u critical -i nix-snowflake-white \
                "NixOS — new closure published" "CI says: $line — auto-starting switch (dashboards will open)"
              ${cfg.repo}/build.sh switch >> /tmp/autotrigger-switch.log 2>&1 \
                || ${pkgs.libnotify}/bin/notify-send -u critical -i emblem-important \
                     "NixOS auto-switch FAILED" "see /tmp/autotrigger-switch.log"
              ;;
          esac
        done
      sleep 10
    done
  '';
in
lib.mkIf (cfg.enable or false) {
  systemd.user.services.nixos-switch-autotrigger = {
    description = "Auto-run build.sh switch when CI publishes a new closure (ntfy SSE)";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    # NixOS's default systemd-unit PATH is coreutils/findutils/gnugrep/gnused/
    # systemd ONLY — build.sh switch needs the real toolchain (awk, nix, docker,
    # jq, gh, ssh, ...) it gets when run interactively. This host runs
    # *standalone* home-manager (build.sh calls `home-manager switch` directly,
    # not the NixOS-integrated module), so HM-installed packages land in
    # ~/.nix-profile/bin, NOT /etc/profiles/per-user/<user>/bin — that path is
    # only populated by NixOS-integrated HM, which this system does not use.
    # %h/.nix-profile/bin comes first so this unit sees the same `git`/`nix`/`jq`
    # an interactive shell resolves (HM profile shadows the system profile there).
    environment = {
      # nixos/modules/system/boot/systemd/user.nix already sets a default PATH
      # for every systemd.user.services.<name> — plain assignment conflicts
      # with it (no priority ⇒ "conflicting definition values"). Force ours.
      # %h expands to the unit's home directory (specifier expansion works in
      # Environment=, per systemd.exec(5)) — kept alongside /etc/profiles/per-user/diego
      # below in case NixOS-integrated HM packages ever show up there too.
      PATH = lib.mkForce "%h/.nix-profile/bin:/run/current-system/sw/bin:/etc/profiles/per-user/diego/bin:/nix/var/nix/profiles/default/bin";
    };
    serviceConfig = {
      ExecStart = listener;
      Restart = "always";
      RestartSec = 30;
    };
  };
}
