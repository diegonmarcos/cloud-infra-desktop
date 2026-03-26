{ lib, stdenv, fetchurl, autoPatchelfHook, gcc-unwrapped, openssl }:

let
  version = "0.12.2";
  # Full-featured build: fastembed + huggingface + graphrag, glibc-linked
  # Docker image: ghcr.io/diegonmarcos/octocode-fastembed-huggingface-graphrag-cpu-x86-linux-static
  assets = {
    x86_64-linux = {
      url = "https://github.com/diegonmarcos/ops-Tooling/releases/download/octocode-v${version}-fastembed/octocode-${version}-fastembed-x86_64";
      hash = "sha256-jTYcvdWIjQ8IVJR1U77bTUd+1a6wAnYmfp4kNbFp3aM=";
    };
  };
  asset = assets.${stdenv.hostPlatform.system} or (throw "octocode: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "octocode";
  inherit version;

  src = fetchurl {
    inherit (asset) url hash;
  };

  dontUnpack = true;

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ gcc-unwrapped.lib openssl ];

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/octocode
    chmod +x $out/bin/octocode
  '';

  meta = with lib; {
    description = "Semantic code search with FastEmbed, HuggingFace, GraphRAG, and LanceDB";
    homepage = "https://github.com/Muvon/octocode";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
