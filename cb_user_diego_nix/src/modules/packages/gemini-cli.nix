# Gemini CLI - Google's AI coding assistant
# Proper FOD approach using npm tarball + prefetched dependencies
{ lib, buildNpmPackage, fetchurl, nodejs, makeWrapper, pkg-config, libsecret, python3 }:

buildNpmPackage rec {
  pname = "gemini-cli";
  version = "0.27.0";

  # Use pre-built npm tarball (has dist/ already compiled)
  src = fetchurl {
    url = "https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-${version}.tgz";
    hash = "sha256-wTbwHC2gFTDq85trg/kRczio8QjHmOVNWG2RrB6AiEQ=";
  };

  # Package-lock.json generated from npm tarball
  postPatch = ''
    cp ${./gemini-cli-package-lock.json} package-lock.json
  '';

  # Hash computed via: nix run nixpkgs#prefetch-npm-deps -- package-lock.json
  npmDepsHash = "sha256-V6TvgcvfTaMgdoKo2TTp3tx7cCzV4keNYxh3OheOk58=";

  # Native deps for keytar (credential storage)
  nativeBuildInputs = [ pkg-config python3 makeWrapper ];
  buildInputs = [ libsecret ];

  # Skip npm build - dist/ is already pre-built in tarball
  dontNpmBuild = true;

  # The tarball extracts to 'package/' but buildNpmPackage expects source root
  sourceRoot = "package";

  meta = with lib; {
    description = "Gemini CLI - Google's AI coding assistant for the terminal";
    homepage = "https://github.com/google-gemini/gemini-cli";
    license = licenses.asl20;
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "gemini";
  };
}
