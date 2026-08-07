{ lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper, gcc-unwrapped, libgcc }:
# Fetch my-ai and my-ai-dash prebuilt aarch64 binaries from the GH release,
# apply autoPatchelfHook so they run on nix-on-droid, and install them.
# Hashes live in ./my-ai-hashes.json (bumped by ship-my-ai-app.yml GHA).
let
  hashes  = builtins.fromJSON (builtins.readFile ./my-ai-hashes.json);
  baseUrl = "https://github.com/diegonmarcos/unix/releases/download/my-ai-latest";
in
stdenv.mkDerivation {
  pname   = "my-ai";
  version = "latest";

  src = fetchurl {
    url  = "${baseUrl}/my-ai-aarch64";
    hash = hashes."my-ai";
  };

  dashSrc = fetchurl {
    url  = "${baseUrl}/my-ai-dash-aarch64";
    hash = hashes."my-ai-dash";
  };

  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
  buildInputs       = [ gcc-unwrapped.lib libgcc ];

  dontUnpack = true;

  installPhase = ''
    install -Dm755 $src     $out/bin/my-ai
    install -Dm755 $dashSrc $out/libexec/my-ai/my-ai-dash

    wrapProgram $out/bin/my-ai \
      --set MY_AI_DASH_BIN "$out/libexec/my-ai/my-ai-dash"
  '';

  meta = with lib; {
    description = "my-ai — Claude Code via the Headroom compression proxy (aarch64)";
    mainProgram = "my-ai";
  };
}
