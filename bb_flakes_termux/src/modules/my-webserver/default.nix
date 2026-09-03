# my-webserver on nix-on-droid — the always-on :8000 instance that backs the
# local editing tools, plus the fish auto-start hook and the runit service.
#
# The BINARY comes from the app's own flake now. What used to be here: a
# fetchurl derivation, its own hashes.json, and the patchelfUnstable plumbing
# needed because nixpkgs-24.05's patchelf 0.15.0 SIGABRTs ("Assertion
# !section.empty() failed") replacing a different-length PT_INTERP on a binary
# this size, plus dontStrip because stripping corrupts the Node SEA's injected
# blob sections. All of it correct, all of it also in ba_flakes_desktop, with
# vm-pilot describing the unit a third time.
#
# It lives once now, in da__shared/lib/prebuilt.nix. Both mistakes were re-made
# while moving it and both dumped core.
#
# The SERVICE stays here, unlike on desktop: nix-on-droid has no systemd, so
# the shared module's systemd.user.services has nothing to render into. runit
# and the fish hook are this platform's answer and are genuinely local.
{ config, pkgs, lib, myWebserverPkg, ... }:

let
  serviceName = "my-webserver";
  httpdBin = myWebserverPkg;

  # kept as a separate file rather than a cross-tree share since the two
  # module trees (home-manager desktop vs nix-on-droid termux) don't share
  # a common lib path). The only value Nix ever interpolated into it was the
  # fetched binary's store path, now passed via runtimeEnv instead of a
  # baked-in ${httpdBin} string.
  #
  # This wrapper is the on-demand / interactive-shell path (fish auto-start).
  # The runit service (sv my-webserver) is the real
  # background-supervision path — see run script below. Both exec the same
  # fetched binary; running both at once will fight over the port exactly
  # like the old http-dev wrapper + disabled systemd unit did on desktop.
  httpdWrapperScript = pkgs.writeShellApplication {
    name = "my-webserver";
    runtimeInputs = [ pkgs.coreutils ];
    runtimeEnv = {
      HTTPD_WEB_SERVER_BIN = "${httpdBin}/bin/my-webserver";
      # Write API (/__api__/write, /__api__/git) is opt-in and off by default
      # in the server itself. Enabled here so the one always-on :8000 instance
      # can back local editing tools instead of each one shipping its own
      # second webserver. Mutating routes are still loopback-only and require
      # the custom X-Httpd-Write header, so cross-origin pages cannot reach
      # them.
      HTTPD_WRITE = "1";

      # ...but the header only constrains browsers, and on Android any local
      # app can reach 127.0.0.1. ROOT is $HOME, so write mode on its own would
      # expose ~/.bashrc, the fish config and ~/.ssh — all of which execute or
      # authenticate on next login. Writes are therefore confined to the few
      # directories the editing tools actually touch; everything else under
      # $HOME stays readable but not writable. Paths are $HOME-relative, and
      # the server fails closed if this is empty.
      HTTPD_WRITE_ROOTS = builtins.concatStringsSep ":" [
        "/git/front/b-Media/mySocials/src/data"
        "/git/front/b-Media/mySocials/dist"
        "/git/front-assets-cdn/b-Media/mySocials/static/media"
      ];

      # Shared secret gating the write API, rendered from ./secrets.yaml by the
      # activation below. The allowlist bounds WHAT can be written; this bounds
      # WHO can write. It matters most on Android, where any installed app can
      # reach 127.0.0.1 but cannot read a 0600 file owned by another UID.
      HTTPD_WRITE_TOKEN_FILE = "${config.home.homeDirectory}/.cache/my-webserver.token";
    };
    text = builtins.readFile ./my-webserver.sh;
  };

  # runit run script — `exec`'d, NOT forked, per runit convention: runsv is
  # the supervisor and needs to remain PID 1 of this service's process group.
  # Fixed port 8000 / $HOME root, matching the wrapper's defaults — the
  # runit service is meant to always-serve-$HOME-on-8000; use the wrapper
  # directly for one-off custom roots/ports.
  runitRunScript = pkgs.writeShellScript "my-webserver-run" ''
    # Same opt-in write scope as the interactive wrapper above — see the
    # HTTPD_WRITE_ROOTS comment there for why writes are confined rather than
    # granted across all of $HOME.
    export HTTPD_WRITE=1
    export HTTPD_WRITE_ROOTS="/git/front/b-Media/mySocials/src/data:/git/front/b-Media/mySocials/dist:/git/front-assets-cdn/b-Media/mySocials/static/media"
    export HTTPD_WRITE_TOKEN_FILE="$HOME/.cache/my-webserver.token"
    exec "${httpdBin}/bin/my-webserver" 8000 "$HOME"
  '';
in
{
  home.file.".local/bin/my-webserver".source =
    "${httpdWrapperScript}/bin/my-webserver";

  # Render the write-API shared secret out of the sops-encrypted secrets.yaml
  # to a 0600 file. Must run before the fish hook starts the server, since the
  # token is read once at startup. On decrypt failure the script writes nothing
  # and the server fails closed — see token-render.sh for why that direction is
  # the opposite of cloud-ide-sshd's.
  # body in ./token-render.sh (no-inline-scripts decree 2026-08-08)
  home.activation.myWebserverToken = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    YQ_BIN="${pkgs.yq-go}/bin/yq" \
    SECRETS="${./secrets.yaml}" \
    OUT="${config.home.homeDirectory}/.cache/my-webserver.token" \
    ${pkgs.bash}/bin/bash ${./token-render.sh} || true
  '';

  home.file.".termux/service/${serviceName}/run" = {
    source = runitRunScript;
    executable = true;
  };

  # Enable the runit service every activation (idempotent — sv-enable is a
  # no-op symlink-create if already enabled). Best-effort: warns rather than
  # fails if termux-services isn't installed on the underlying Termux prefix,
  # since nix-on-droid doesn't own that install.
  #
  # 2026-08-10: the com.termux.nix app (this flake's target — see the
  # hardcoded prefix path below) ships NO apt/dpkg layer at all (no
  # /usr/etc/apt, no dpkg status db) — `pkg install termux-services` can
  # never succeed here, it's not a "not yet installed" gap. Real runit
  # supervision is unavailable on this app; the fish interactive-shell hook
  # (programs.fish interactiveShellInit — starts this server on shell open)
  # is the actual auto-start path. The warning below reflects that instead
  # of pointing at a dead command.
  home.activation.myWebserverSvEnable = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # Explicit Termux-prefix path — sv-enable is never on the minimal
    # activation PATH, so `command -v` couldn't distinguish "not installed"
    # from "not on PATH" (2026-08-08 audit).
    SV_ENABLE="/data/data/com.termux.nix/files/usr/bin/sv-enable"
    if [ -x "$SV_ENABLE" ]; then
      $DRY_RUN_CMD "$SV_ENABLE" ${serviceName} 2>/dev/null || \
        echo "[${serviceName}] WARNING: sv-enable failed — check runsvdir status (falling back to the fish-shell auto-start hook)"
    else
      echo "[${serviceName}] NOTE: sv-enable not present (com.termux.nix has no apt/termux-services) — relying on the fish interactive-shell auto-start hook instead"
    fi
  '';
}
