# Claude Code CLI - Anthropic's AI coding assistant
# Bun compiled single-binary — fetched from GCS, patched with patchelf (NOT autoPatchelfHook)
# autoPatchelfHook strips the ELF binary and destroys the embedded JS payload.
# patchelf --set-interpreter only patches the ELF header, preserving the trailing JS bundle.
# To bump: update version + hash (nix build will error with correct hash)
{ lib, stdenv, fetchurl, patchelf, glibc }:

let
  version = "2.1.81";
  bucket = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";
in
stdenv.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = fetchurl {
    url = "${bucket}/${version}/linux-x64/claude";
    # To get hash: nix-prefetch-url --type sha256 <url>
    # then nix hash to-sri --type sha256 <hash>
    hash = "sha256-BH4/VZHWI4sI3ZUYcprDNbDo3xyA/pheXX+9osGPwoE=";
  };

  nativeBuildInputs = [ patchelf ];
  buildInputs = [ glibc ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/claude
    chmod 755 $out/bin/claude
    patchelf --set-interpreter ${glibc}/lib/ld-linux-x86-64.so.2 $out/bin/claude
    chmod 555 $out/bin/claude
  '';

  meta = with lib; {
    description = "Claude Code - Anthropic's AI coding assistant for the terminal";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "claude";
  };
}
