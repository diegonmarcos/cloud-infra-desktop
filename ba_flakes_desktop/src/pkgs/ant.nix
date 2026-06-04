# ant — Anthropic's official CLI for the Claude Developer Platform.
#
# Pre-built Go binary tarball from GitHub releases, content-addressed.
# Upstream: https://github.com/anthropics/anthropic-cli/releases
# Checksums: ant_${version}_checksums.txt at the release tag.

{ lib, stdenv, fetchurl, autoPatchelfHook, gcc-unwrapped }:

let
  version = "1.10.0";
  assets = {
    x86_64-linux = {
      arch = "amd64";
      hash = "sha256-bYFFkB7cgSdtXKgD6oI93PGEUrBEk1QoO5H+RImEshU=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-rnPDNS6CcQMs9OF5JxspraJQ9K6FYcUR6X023VXkzYg=";
    };
  };
  asset = assets.${stdenv.hostPlatform.system}
    or (throw "ant: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "ant";
  inherit version;

  src = fetchurl {
    url = "https://github.com/anthropics/anthropic-cli/releases/download/v${version}/ant_${version}_linux_${asset.arch}.tar.gz";
    hash = asset.hash;
  };

  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ gcc-unwrapped.lib ];

  installPhase = ''
    runHook preInstall
    install -D -m 0755 ant $out/bin/ant
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
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "ant";
  };
}
