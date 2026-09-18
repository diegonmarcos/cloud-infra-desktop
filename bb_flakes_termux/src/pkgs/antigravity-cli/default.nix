# antigravity-cli — Google's terminal agent for the Antigravity platform
# (binary name upstream: `agy`).
#
# This is the CLI/headless agent only, NOT the Antigravity desktop IDE. The
# IDE is a VS Code fork that needs a GUI/X server and has no place in a proot
# terminal; the CLI is a flat native binary with a documented headless mode
# (`agy -p "..."`) built exactly for scripted/terminal use, which is what
# nix-on-droid needs.
#
# Same pattern as ../claude-code/default.nix: pull the platform-specific
# pre-built binary from GitHub releases as a content-addressed nix source,
# patchelf onto nix-on-droid's glibc, ship as $out/bin/agy. Bump `version` +
# the matching hash to upgrade.
#
# Confirmed 2026-09-18 by downloading the release asset and reading its ELF
# headers directly (no readelf in this environment, so parsed by hand):
#   e_machine  = AArch64
#   PT_INTERP  = /lib/ld-linux-aarch64.so.1   (glibc dynamic linker, not
#                                              bionic's /system/bin/linker64)
#   DT_NEEDED  = libresolv.so.2 libpthread.so.0 libm.so.6 libdl.so.2
#                librt.so.1 libc.so.6
# — a glibc/aarch64 dynamic binary, exactly what autoPatchelfHook + glibc
# below already handles for ant and claude-code.
#
# Upstream: https://github.com/google-antigravity/antigravity-cli/releases
# The release asset ships as a single flat file named "antigravity" inside
# the tarball; upstream's own install.sh renames it to "agy" on install,
# which this derivation mirrors.

{ stdenv
, fetchurl
, lib
, autoPatchelfHook
, glibc
, gcc-unwrapped
, version ? "1.2.6"
}:

let
  sources = {
    "aarch64-linux" = {
      hash = "sha256-AqCiyGMRP4msaEIm74HeR7mGUjj6wQduj5rqfsX0kUo=";
    };
  };

  src = sources.${stdenv.hostPlatform.system}
    or (throw "antigravity-cli: no prebuilt binary for ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "antigravity-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/google-antigravity/antigravity-cli/releases/download/${version}/agy_cli_linux_arm64.tar.gz";
    hash = src.hash;
  };

  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  # autoPatchelfHook rewrites the binary's PT_INTERP and DT_NEEDED entries
  # to point at the nix-store glibc / libstdc++. nix-on-droid's proot
  # bind-mounts /nix correctly, so the patched paths resolve at runtime.
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ glibc gcc-unwrapped.lib ];

  installPhase = ''
    runHook preInstall
    install -D -m 0755 antigravity $out/bin/agy
    runHook postInstall
  '';

  meta = with lib; {
    description = "Google Antigravity CLI — terminal agent for the Antigravity platform, native binary";
    homepage = "https://github.com/google-antigravity/antigravity-cli";
    license = licenses.unfree;
    platforms = [ "aarch64-linux" ];
    mainProgram = "agy";
  };
}
