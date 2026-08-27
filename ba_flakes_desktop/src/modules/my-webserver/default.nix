# my-webserver — file server with Markdown, JSON/YAML
# table, and Eruda DevTools rendering.
# Provides: my-webserver command (start|stop|status|restart)
#
# Ships as a prebuilt, per-arch Node Single Executable Application binary
# fetched from the rolling GitHub Release (built + published by
# 1_cicd/src/cicd/ship-my-webserver-app.yml), NOT as loose
# source files interpreted by `node script.mjs` — same fetchurl + hashes.json
# pattern as da_my-ai/nix/my-ai.nix. Bump ./hashes.json only via that CI job's
# update-hashes step.
{ config, pkgs, lib, ... }:

let
  hashes  = builtins.fromJSON (builtins.readFile ./hashes.json);
  archMap = { "x86_64-linux" = "x86_64"; "aarch64-linux" = "aarch64"; };
  arch    = archMap.${pkgs.stdenv.hostPlatform.system}
              or (throw "my-webserver: unsupported platform ${pkgs.stdenv.hostPlatform.system}");
  baseUrl = "https://github.com/diegonmarcos/cloud-u-linux/releases/download/my-webserver-latest";
  sys     = hashes.${pkgs.stdenv.hostPlatform.system};

  # The fetched binary is the official nodejs.org release (see
  # ship-my-webserver-app.yml), which ships a generic FHS
  # interpreter (/lib64/ld-linux-x86-64.so.2 or /lib/ld-linux-aarch64.so.1) —
  # absent on a pure-Nix store, so raw-exec fails "cannot execute: required
  # file not found" on any system without that FHS path (e.g. NixOS). We
  # rewrite the interpreter to this system's glibc and set an rpath covering
  # the binary's real (small) runtime dependency set — it statically links
  # zlib/openssl/icu4c/etc, so it only needs glibc + libgcc, confirmed via
  # `readelf -d` on the untouched release binary (2026-08-10). Uses
  # pkgs.unstable.patchelf by full store path rather than autoPatchelfHook's
  # bare `patchelf`: the pinned stable patchelf can SIGABRT
  # ("Assertion !section.empty() failed") replacing a different-length
  # PT_INTERP string on a large binary — same crash class hit and root-caused
  # on the Termux sibling module (bb_flakes_termux), fixed there the same way.
  httpdBin =
    let
      runtimeLibs = [ pkgs.stdenv.cc.libc pkgs.gcc-unwrapped.lib pkgs.libgcc ];
    in
    pkgs.stdenv.mkDerivation {
      pname   = "my-webserver";
      version = "latest";

      src = pkgs.fetchurl {
        url  = "${baseUrl}/my-webserver-${arch}";
        hash = sys.my-webserver;
      };

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

      dontUnpack   = true;

      installPhase = ''
        install -Dm755 $src $out/bin/my-webserver
        "${pkgs.unstable.patchelf}/bin/patchelf" \
          --set-interpreter "$(cat "$NIX_BINTOOLS/nix-support/dynamic-linker")" \
          --set-rpath "${lib.makeLibraryPath runtimeLibs}" \
          $out/bin/my-webserver
      '';
    };

  # Shell body lives in ./my-webserver.sh. The only value
  # Nix ever interpolated into it was the fetched binary's store path, now
  # passed via runtimeEnv instead of baked into the script text.
  httpdWrapperScript = pkgs.writeShellApplication {
    name = "my-webserver";
    runtimeInputs = [ pkgs.coreutils ];
    runtimeEnv = {
      HTTPD_WEB_SERVER_BIN = "${httpdBin}/bin/my-webserver";
      # Deliberately NOT setting HTTPD_WRITE here. The write API
      # (/__api__/write, /__api__/git) exists for the termux device, where the
      # editing tools run against the always-on :8000 instance. Nothing on
      # desktop uses it, and an enabled-but-unused write path is just surface.
      # To turn it on later: set HTTPD_WRITE=1, HTTPD_WRITE_ROOTS to the
      # directories it may touch, and HTTPD_WRITE_TOKEN_FILE to a rendered
      # secret — see bb_flakes_termux's module for the full wiring. The server
      # fails closed without all three.
    };
    text = builtins.readFile ./my-webserver.sh;
  };
in
{
  # Deploy the POSIX wrapper as my-webserver. httpdBin is
  # already a patched, executable nix store path (see installPhase above) —
  # the wrapper chmod +x's it defensively but it's already 555.
  home.file.".local/bin/my-webserver".source =
    "${httpdWrapperScript}/bin/my-webserver";

  xdg.desktopEntries.my-webserver = {
    name = "my-webserver";
    comment = "Local file server — Markdown + JSON/YAML tables + Eruda DevTools";
    # NOT %h. The Desktop Entry spec defines no home-directory field code, so
    # desktop-file-validate rejects it and the .desktop derivation fails the
    # build -- which takes home-manager-path and the whole generation with it.
    # %h is only valid in systemd units (see the ExecStart below, where it is
    # correct). Here the path has to be interpolated at eval time.
    exec = "my-webserver restart 8000 ${config.home.homeDirectory}";
    icon = "my-webserver";
    terminal = false;
    categories = [ "Network" "Utility" ];
  };

  # Systemd user service — start on login (not per-shell like termux)
  systemd.user.services.my-webserver = {
    Unit.Description = "my-webserver — file server (Markdown + JSON/YAML + Eruda)";
    Service = {
      ExecStart = "${httpdBin}/bin/my-webserver 8000 %h";
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
