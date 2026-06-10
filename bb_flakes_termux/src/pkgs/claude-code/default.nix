# claude-code — Anthropic's CLI as a permanent nix derivation.
#
# Why this exists:
#   The previous setup ran `npm install -g @anthropic-ai/claude-code` at every
#   home-manager activation. On Android nix-on-droid, npm gets SIGTERM'd by
#   the OOM killer ~50% of the time, leaving the user with NO claude binary
#   and an unhelpful `|| true` swallowing the failure.
#
#   This derivation pulls the platform-specific NATIVE binary tarball that
#   Anthropic publishes (pre-built for linux-arm64-musl) from npm registry as
#   a content-addressed nix source. Build = extract + chmod + symlink — zero
#   network at runtime, deterministic, never disappears.
#
# Result:
#   $out/bin/claude  — native binary, ~75 MB
#   Permanent nix-store path; ~/.nix-profile/bin/claude is a stable symlink.

{ stdenv
, fetchurl
, lib
, autoPatchelfHook
, glibc
, gcc-unwrapped
, version ? "2.1.170"
}:

let
  # Anthropic publishes platform-specific native tarballs. We use the GLIBC
  # arm64 build (NOT musl) because nix-on-droid's stdenv targets glibc — the
  # autoPatchelfHook below rewrites the binary's loader to ${glibc}/lib/ld...
  # so it runs cleanly inside proot.
  sources = {
    "aarch64-linux" = {
      pkg = "claude-code-linux-arm64";
      hash = "sha256-np1UdJEhAz6o/1mJNPYVfqjmUWjK+/nN7IVjb4g5wU4=";
    };
  };

  src = sources.${stdenv.hostPlatform.system}
    or (throw "claude-code: no native binary for ${stdenv.hostPlatform.system}");

  pkgName = src.pkg;

in
stdenv.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/${pkgName}/-/${pkgName}-${version}.tgz";
    hash = src.hash;
  };

  # The npm tarball extracts to ./package/* — sourceRoot tells stdenv to cd
  # there before checkPhase / installPhase.
  sourceRoot = "package";

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
    install -D -m 0755 claude $out/bin/claude
    runHook postInstall
  '';

  meta = with lib; {
    description = "Anthropic Claude Code CLI — native binary, no npm";
    homepage = "https://www.npmjs.com/package/@anthropic-ai/claude-code";
    license = licenses.unfree;
    platforms = [ "aarch64-linux" ];
    mainProgram = "claude";
  };
}
