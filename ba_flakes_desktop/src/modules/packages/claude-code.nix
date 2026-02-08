# Claude Code CLI - Anthropic's AI coding assistant
# Pre-bundled npm package, no build step needed
{ lib, stdenv, fetchurl, nodejs, makeWrapper }:

stdenv.mkDerivation rec {
  pname = "claude-code";
  version = "2.1.31";

  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    hash = "sha256-YZrcQyi9c5B/9YJU3h2Lz4XUWGPh0qg8CypEmo7fEdE=";
  };

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ nodejs ];

  unpackPhase = ''
    tar -xzf $src
    mv package $out
  '';

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin
    makeWrapper ${nodejs}/bin/node $out/bin/claude \
      --add-flags "$out/cli.js"
  '';

  meta = with lib; {
    description = "Claude Code - Anthropic's AI coding assistant for the terminal";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.unfree;
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "claude";
  };
}
