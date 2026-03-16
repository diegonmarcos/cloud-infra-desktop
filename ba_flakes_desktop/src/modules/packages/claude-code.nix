# Claude Code CLI - Anthropic's AI coding assistant
# Native binary — fetched from GCS, patched with autoPatchelfHook
# To bump: update version + hash (nix build will error with correct hash)
{ lib, stdenv, fetchurl, autoPatchelfHook, glibc }:

let
  version = "2.1.76";
  bucket = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";
in
stdenv.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    url = "${bucket}/${version}/linux-x64/claude";
    # To get hash: nix-prefetch-url --type sha256 <url>
    # then nix hash to-sri --type sha256 <hash>
    hash = "";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ glibc ];

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/claude
    chmod +x $out/bin/claude
  '';

  meta = with lib; {
    description = "Claude Code - Anthropic's AI coding assistant for the terminal";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "claude";
  };
}
