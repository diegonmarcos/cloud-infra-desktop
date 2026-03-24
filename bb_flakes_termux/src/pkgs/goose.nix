{ lib, stdenv, fetchurl, autoPatchelfHook, gcc-unwrapped, libgcc }:

let
  version = "1.28.0";
  assets = {
    x86_64-linux = {
      url = "https://github.com/block/goose/releases/download/v${version}/goose-x86_64-unknown-linux-gnu.tar.bz2";
      hash = "sha256:0jq7cm6hcng3f9kw1mwqn3qz17w6spg1pff50ww0yihzgdpry121";
    };
    aarch64-linux = {
      url = "https://github.com/block/goose/releases/download/v${version}/goose-aarch64-unknown-linux-gnu.tar.bz2";
      hash = "sha256:1xr4l4d0hmwwyp5rhrlnximlaqgb1zl1lk27bcsgmasc74im65ym";
    };
  };
  asset = assets.${stdenv.hostPlatform.system} or (throw "goose: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "goose";
  inherit version;

  src = fetchurl {
    inherit (asset) url hash;
  };

  sourceRoot = ".";
  unpackPhase = "tar xf $src";

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = [ gcc-unwrapped.lib libgcc ];

  installPhase = ''
    mkdir -p $out/bin
    cp goose $out/bin/
    chmod +x $out/bin/goose
  '';

  meta = with lib; {
    description = "Goose — AI-powered developer agent by Block (MCP-native)";
    homepage = "https://github.com/block/goose";
    license = licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "goose";
  };
}
