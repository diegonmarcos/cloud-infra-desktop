# httpd-web-server-json-md-eruda (Termux) — file server with Markdown,
# JSON/YAML table, and Eruda DevTools rendering.
#
# Fetches the same prebuilt aarch64 Node SEA binary the desktop module fetches
# (published by 1_cicd/src/cicd/ship-httpd-web-server-json-md-eruda.yml
# to the rolling httpd-web-server-json-md-eruda-latest GitHub Release) — same
# fetchurl + hashes.json pattern as da_my-ai (see
# bb_flakes_termux/src/pkgs/my-ai-hashes.json). No more loose .mjs + lib
# assets shipped via home.file.
#
# Provides: httpd-web-server-json-md-eruda command (start|stop|status|restart),
# PID-file wrapper style copied from ../cloud-ide-sshd/default.nix (the only
# existing Termux daemon pattern in this repo).
#
# Also wires a REAL background service via runit (termux-services), since
# previously this tool only ran on-demand from an interactive shell. This is
# genuinely new infra for the repo — scoped narrowly to this one service, not
# a general runit/termux-services framework:
#   - requires `pkg install termux-services` on the underlying Termux
#     install (termux-services + runit live in Termux's own $PREFIX, managed
#     by its `pkg`/apt, NOT the nix store — nix-on-droid coexists with that
#     prefix rather than rebuilding it) — home.activation below only calls
#     `sv-enable` best-effort and warns (does not fail activation) if it's
#     missing.
#   - $HOME/.termux/service/httpd-web-server-json-md-eruda/run execs the
#     fetched binary directly (no fork), per runit convention: runsv restarts
#     it automatically on exit, giving real supervision the on-demand
#     PID-file wrapper never had.
{ config, pkgs, lib, patchelfUnstable, ... }:

let
  hashes  = builtins.fromJSON (builtins.readFile ./hashes.json);
  baseUrl = "https://github.com/diegonmarcos/cloud-unix/releases/download/httpd-web-server-json-md-eruda-latest";

  # A raw pkgs.fetchurl result is NOT executable on nix-on-droid: the fetched
  # binary is the official nodejs.org release (see
  # ship-httpd-web-server-json-md-eruda.yml) with a generic FHS interpreter
  # (/lib/ld-linux-aarch64.so.1), which doesn't exist on this flake's
  # nix-on-droid store — "cannot execute: required file not found" (same
  # class of bug da_my-ai already hit — see pkgs/my-ai.nix). We rewrite the
  # interpreter to this system's actual glibc and set an rpath covering the
  # official binary's real (small) runtime dependency set — it statically
  # links zlib/openssl/icu4c/etc, so it only needs glibc + libgcc, confirmed
  # via `readelf -d` on the untouched release binary (2026-08-10).
  httpdBin =
    let
      runtimeLibs = [ pkgs.stdenv.cc.libc pkgs.gcc-unwrapped.lib pkgs.libgcc ];
    in
    pkgs.stdenv.mkDerivation {
      pname   = "httpd-web-server-json-md-eruda";
      version = "latest";

      src = pkgs.fetchurl {
        url  = "${baseUrl}/httpd-web-server-json-md-eruda-aarch64";
        hash = hashes.httpd-web-server-json-md-eruda;
      };

      # nixpkgs-24.05's pinned patchelf (0.15.0) SIGABRTs ("Assertion
      # !section.empty() failed") rewriting the interpreter on this binary.
      # autoPatchelfHook can't route around it: its auto-patchelf.py invokes
      # a bare `patchelf`, which always resolves to stdenv's own pinned one
      # regardless of nativeBuildInputs ordering — setup.sh appends
      # `initialPath` (which includes stdenv's patchelf) to PATH *before*
      # any nativeBuildInputs are processed, and addToSearchPath only ever
      # appends, so nativeBuildInputs entries always lose that lookup
      # (confirmed against nixos-24.05's stdenv/generic/setup.sh). The only
      # reliable fix is calling patchelfUnstable by its full store path,
      # bypassing PATH entirely — same trick auto-patchelf.py itself uses to
      # find the interpreter, via $NIX_BINTOOLS/nix-support/dynamic-linker.
      # dontPatchELF disables stdenv's own automatic fixup-phase patchelf
      # pass too, which would otherwise hit the same crash.
      buildInputs  = runtimeLibs;
      dontPatchELF = true;

      # stdenv's fixupPhase runs `strip -S -p` unconditionally unless told
      # not to — dontPatchELF only skips the patchelf fixup pass, not this.
      # strip corrupts this binary's ELF version tables (postject's injected
      # SEA blob sections aren't a layout strip expects): confirmed by
      # reproducing byte-for-byte (127249392 bytes, identical crash — "no
      # version information available" / blank "undefined symbol") via
      # manually running stdenv's own strip on an otherwise-working patched
      # copy, 2026-08-10.
      dontStrip = true;

      dontUnpack = true;

      installPhase = ''
        install -Dm755 $src $out/bin/httpd-web-server-json-md-eruda
        "${patchelfUnstable}/bin/patchelf" \
          --set-interpreter "$(cat "$NIX_BINTOOLS/nix-support/dynamic-linker")" \
          --set-rpath "${lib.makeLibraryPath runtimeLibs}" \
          $out/bin/httpd-web-server-json-md-eruda
      '';
    };

  serviceName = "httpd-web-server-json-md-eruda";

  # Shell body lives in ./httpd-web-server-json-md-eruda.sh (duplicated
  # verbatim from the desktop module's sibling script — same wrapper logic,
  # kept as a separate file rather than a cross-tree share since the two
  # module trees (home-manager desktop vs nix-on-droid termux) don't share
  # a common lib path). The only value Nix ever interpolated into it was the
  # fetched binary's store path, now passed via runtimeEnv instead of a
  # baked-in ${httpdBin} string.
  #
  # This wrapper is the on-demand / interactive-shell path (fish auto-start).
  # The runit service (sv httpd-web-server-json-md-eruda) is the real
  # background-supervision path — see run script below. Both exec the same
  # fetched binary; running both at once will fight over the port exactly
  # like the old http-dev wrapper + disabled systemd unit did on desktop.
  httpdWrapperScript = pkgs.writeShellApplication {
    name = "httpd-web-server-json-md-eruda";
    runtimeInputs = [ pkgs.coreutils ];
    runtimeEnv = {
      HTTPD_WEB_SERVER_BIN = "${httpdBin}/bin/httpd-web-server-json-md-eruda";
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
      HTTPD_WRITE_TOKEN_FILE = "${config.home.homeDirectory}/.cache/httpd-web-server-json-md-eruda.token";
    };
    text = builtins.readFile ./httpd-web-server-json-md-eruda.sh;
  };

  # runit run script — `exec`'d, NOT forked, per runit convention: runsv is
  # the supervisor and needs to remain PID 1 of this service's process group.
  # Fixed port 8000 / $HOME root, matching the wrapper's defaults — the
  # runit service is meant to always-serve-$HOME-on-8000; use the wrapper
  # directly for one-off custom roots/ports.
  runitRunScript = pkgs.writeShellScript "httpd-web-server-json-md-eruda-run" ''
    # Same opt-in write scope as the interactive wrapper above — see the
    # HTTPD_WRITE_ROOTS comment there for why writes are confined rather than
    # granted across all of $HOME.
    export HTTPD_WRITE=1
    export HTTPD_WRITE_ROOTS="/git/front/b-Media/mySocials/src/data:/git/front/b-Media/mySocials/dist:/git/front-assets-cdn/b-Media/mySocials/static/media"
    export HTTPD_WRITE_TOKEN_FILE="$HOME/.cache/httpd-web-server-json-md-eruda.token"
    exec "${httpdBin}/bin/httpd-web-server-json-md-eruda" 8000 "$HOME"
  '';
in
{
  home.file.".local/bin/httpd-web-server-json-md-eruda".source =
    "${httpdWrapperScript}/bin/httpd-web-server-json-md-eruda";

  # Render the write-API shared secret out of the sops-encrypted secrets.yaml
  # to a 0600 file. Must run before the fish hook starts the server, since the
  # token is read once at startup. On decrypt failure the script writes nothing
  # and the server fails closed — see token-render.sh for why that direction is
  # the opposite of cloud-ide-sshd's.
  # body in ./token-render.sh (no-inline-scripts decree 2026-08-08)
  home.activation.httpdWebServerJsonMdErudaToken = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    YQ_BIN="${pkgs.yq-go}/bin/yq" \
    SECRETS="${./secrets.yaml}" \
    OUT="${config.home.homeDirectory}/.cache/httpd-web-server-json-md-eruda.token" \
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
  home.activation.httpdWebServerJsonMdErudaSvEnable = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
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
