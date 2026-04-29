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
, version ? "2.1.123"
}:

let
  # Pick the right tarball for the build host. musl arm64 works on bionic
  # (Termux/nix-on-droid) AND on regular alpine/musl Linux. glibc arm64 for
  # standard NixOS aarch64. x86_64 fallbacks for desktop builds.
  sources = {
    "aarch64-linux" = {
      pkg = "claude-code-linux-arm64-musl";
      hash = "sha256-3t09HB7VyYbran6C9OXdTMT6eSpEYx1gDz4yH+wFQa8=";
    };
    # Note: nix-on-droid's stdenv is aarch64-linux. If switching to glibc
    # variant later, swap the entry above for:
    #   pkg = "claude-code-linux-arm64";
    #   hash = "sha256-WIXjh2hgJNrrDLEe74R/njYhdlrldwMAdwjFopN8lxA=";
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
  dontPatchELF = true;  # Android binary; patchELF would corrupt the loader.

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
