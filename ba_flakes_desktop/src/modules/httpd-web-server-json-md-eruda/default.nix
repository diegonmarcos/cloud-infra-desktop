# httpd-web-server-json-md-eruda — file server with Markdown, JSON/YAML
# table, and Eruda DevTools rendering.
# Provides: httpd-web-server-json-md-eruda command (start|stop|status|restart)
#
# Ships as a prebuilt, per-arch Node Single Executable Application binary
# fetched from the rolling GitHub Release (built + published by
# 1_workflows/src/cicd/ship-httpd-web-server-json-md-eruda.yml), NOT as loose
# source files interpreted by `node script.mjs` — same fetchurl + hashes.json
# pattern as da_my-ai/nix/my-ai.nix. Bump ./hashes.json only via that CI job's
# update-hashes step.
{ config, pkgs, lib, ... }:

let
  hashes  = builtins.fromJSON (builtins.readFile ./hashes.json);
  archMap = { "x86_64-linux" = "x86_64"; "aarch64-linux" = "aarch64"; };
  arch    = archMap.${pkgs.stdenv.hostPlatform.system}
              or (throw "httpd-web-server-json-md-eruda: unsupported platform ${pkgs.stdenv.hostPlatform.system}");
  baseUrl = "https://github.com/diegonmarcos/unix/releases/download/httpd-web-server-json-md-eruda-latest";
  sys     = hashes.${pkgs.stdenv.hostPlatform.system};

  # The fetched binary is the official nodejs.org release (see
  # ship-httpd-web-server-json-md-eruda.yml), which ships a generic FHS
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
      pname   = "httpd-web-server-json-md-eruda";
      version = "latest";

      src = pkgs.fetchurl {
        url  = "${baseUrl}/httpd-web-server-json-md-eruda-${arch}";
        hash = sys.httpd-web-server-json-md-eruda;
      };

      buildInputs  = runtimeLibs;
      dontPatchELF = true;
      dontUnpack   = true;

      installPhase = ''
        install -Dm755 $src $out/bin/httpd-web-server-json-md-eruda
        "${pkgs.unstable.patchelf}/bin/patchelf" \
          --set-interpreter "$(cat "$NIX_BINTOOLS/nix-support/dynamic-linker")" \
          --set-rpath "${lib.makeLibraryPath runtimeLibs}" \
          $out/bin/httpd-web-server-json-md-eruda
      '';
    };

  # Shell body lives in ./httpd-web-server-json-md-eruda.sh. The only value
  # Nix ever interpolated into it was the fetched binary's store path, now
  # passed via runtimeEnv instead of baked into the script text.
  httpdWrapperScript = pkgs.writeShellApplication {
    name = "httpd-web-server-json-md-eruda";
    runtimeInputs = [ pkgs.coreutils ];
    runtimeEnv = {
      HTTPD_WEB_SERVER_BIN = "${httpdBin}/bin/httpd-web-server-json-md-eruda";
    };
    text = builtins.readFile ./httpd-web-server-json-md-eruda.sh;
  };
in
{
  # Deploy the POSIX wrapper as httpd-web-server-json-md-eruda. httpdBin is
  # already a patched, executable nix store path (see installPhase above) —
  # the wrapper chmod +x's it defensively but it's already 555.
  home.file.".local/bin/httpd-web-server-json-md-eruda".source =
    "${httpdWrapperScript}/bin/httpd-web-server-json-md-eruda";

  xdg.desktopEntries.httpd-web-server-json-md-eruda = {
    name = "httpd-web-server-json-md-eruda";
    comment = "Local file server — Markdown + JSON/YAML tables + Eruda DevTools";
    # NOT %h. The Desktop Entry spec defines no home-directory field code, so
    # desktop-file-validate rejects it and the .desktop derivation fails the
    # build -- which takes home-manager-path and the whole generation with it.
    # %h is only valid in systemd units (see the ExecStart below, where it is
    # correct). Here the path has to be interpolated at eval time.
    exec = "httpd-web-server-json-md-eruda restart 8000 ${config.home.homeDirectory}";
    icon = "httpd-web-server-json-md-eruda";
    terminal = false;
    categories = [ "Network" "Utility" ];
  };

  # Systemd user service — start on login (not per-shell like termux)
  systemd.user.services.httpd-web-server-json-md-eruda = {
    Unit.Description = "httpd-web-server-json-md-eruda — file server (Markdown + JSON/YAML + Eruda)";
    Service = {
      ExecStart = "${httpdBin}/bin/httpd-web-server-json-md-eruda 8000 %h";
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
