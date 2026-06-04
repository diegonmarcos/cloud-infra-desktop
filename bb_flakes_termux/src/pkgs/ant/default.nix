# ant — Anthropic's official CLI for the Claude Developer Platform.
#
# Same pattern as ./claude-code/default.nix: pull the platform-specific
# pre-built binary from GitHub releases as a content-addressed nix source,
# patchelf onto nix-on-droid's glibc, ship as $out/bin/ant. Bump
# `version` + the matching hash to upgrade.
#
# Upstream: https://github.com/anthropics/anthropic-cli/releases
# Checksums: ant_${version}_checksums.txt at the release tag.

{ stdenv
, fetchurl
, lib
, autoPatchelfHook
, glibc
, gcc-unwrapped
, version ? "1.10.0"
}:

let
  sources = {
    "aarch64-linux" = {
      arch = "arm64";
      hash = "sha256-rnPDNS6CcQMs9OF5JxspraJQ9K6FYcUR6X023VXkzYg=";
    };
    "x86_64-linux" = {
      arch = "amd64";
      hash = "sha256-bYFFkB7cgSdtXKgD6oI93PGEUrBEk1QoO5H+RImEshU=";
    };
  };

  src = sources.${stdenv.hostPlatform.system}
    or (throw "ant: no prebuilt binary for ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "ant";
  inherit version;

  src = fetchurl {
    url = "https://github.com/anthropics/anthropic-cli/releases/download/v${version}/ant_${version}_linux_${src.arch}.tar.gz";
    hash = src.hash;
  };

  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  # Go binary is mostly static, but autoPatchelfHook is harmless on a static
  # ELF and necessary if upstream ever switches to a glibc-linked build.
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ glibc gcc-unwrapped.lib ];

  installPhase = ''
    runHook preInstall
    install -D -m 0755 ant $out/bin/ant
    # Bash/zsh/fish completions shipped in the tarball — install where
    # nix-on-droid's profile picks them up.
    if [ -d completions ]; then
      install -D -m 0644 completions/ant.bash $out/share/bash-completion/completions/ant 2>/dev/null || true
      install -D -m 0644 completions/ant.zsh  $out/share/zsh/site-functions/_ant       2>/dev/null || true
      install -D -m 0644 completions/ant.fish $out/share/fish/vendor_completions.d/ant.fish 2>/dev/null || true
    fi
    if [ -d manpages ]; then
      for m in manpages/*; do
        install -D -m 0644 "$m" "$out/share/man/man1/$(basename "$m")" 2>/dev/null || true
      done
    fi
    runHook postInstall
  '';

  meta = with lib; {
    description = "Anthropic Claude Developer Platform CLI";
    homepage = "https://github.com/anthropics/anthropic-cli";
    license = licenses.mit;
    platforms = [ "aarch64-linux" "x86_64-linux" ];
    mainProgram = "ant";
  };
}
