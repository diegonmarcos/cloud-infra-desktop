# curl/wget wrapper: auto-inject Authelia bearer token for *.diegonmarcos.com
# Transparent — all other URLs pass through unmodified.
# Uses hiPrio nix packages so wrappers override real binaries in ~/.nix-profile/bin
{ config, lib, pkgs, ... }:

let
  tokenFile = "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/cloud-admin.json";

  # Runtime data for curl-wget-wrapper.sh: which header flag each wrapper
  # uses, plus the shared token file, read at RUNTIME via jq instead of
  # being duplicated per-wrapper via Nix interpolation.
  wrappers = [
    { name = "curl"; header_flag = "-H"; }
    { name = "wget"; header_flag = "--header"; }
  ];

  curlWgetWrapperJson = builtins.toJSON {
    token_file = tokenFile;
    wrappers = wrappers;
  };

  realCurl = "${pkgs.curl}/bin/curl";
  realWget = "${pkgs.wget}/bin/wget";

  # Extracted from the formerly per-binary Nix-interpolated `mkWrapperPkg`
  # body — now ONE shared script (curl-wget-wrapper.sh), the real binary
  # passed via runtimeEnv (same pattern as nix-command-catcher.sh's
  # $CATCHER_REAL), which wrapper is running passed via $WRAP_NAME.
  mkWrapperPkg = name: realBin: pkgs.writeShellApplication {
    inherit name;
    # nounset ONLY — deliberately dropping writeShellApplication's default
    # errexit+pipefail. This wrapper must NEVER fail the caller: every exit
    # path is an `exec "$REAL" "$@"`, and a bad/missing config must fall
    # through to the real binary. Under errexit a single failing `$(jq ...)`
    # would kill the wrapper instead, so curl/wget would appear broken.
    # The script's own `set -u` cannot undo this — bashOptions is the only
    # place errexit can be turned off.
    bashOptions = [ "nounset" ];
    runtimeInputs = [ pkgs.jq ];
    runtimeEnv = {
      WRAP_REAL = realBin;
      WRAP_NAME = name;
    };
    text = builtins.readFile ./curl-wget-wrapper.sh;
  };

in
{
  xdg.configFile."cloud-data/curl-wget-wrapper.json".text = curlWgetWrapperJson;

  home.packages = [
    (lib.hiPrio (mkWrapperPkg "curl" realCurl))
    (lib.hiPrio (mkWrapperPkg "wget" realWget))
  ];
}
