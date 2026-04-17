# curl/wget wrapper: auto-inject Authelia bearer token for *.diegonmarcos.com
# Transparent — all other URLs pass through unmodified.
# Uses hiPrio nix packages so wrappers override real binaries in ~/.nix-profile/bin
{ config, lib, pkgs, ... }:

let
  tokenFile = "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/cloud-admin.json";

  realCurl = "${pkgs.curl}/bin/curl";
  realWget = "${pkgs.wget}/bin/wget";

  mkWrapperPkg = name: realBin: headerFlag: pkgs.writeShellScriptBin name ''
    # Re-entry guard
    if [ "''${_CURL_WRAP:-}" = "1" ]; then
      exec ${realBin} "$@"
    fi
    export _CURL_WRAP=1

    # Check if any arg matches *.diegonmarcos.com*
    # Skip injection if user already provides an Authorization header
    _needs_token=0
    _has_auth=0
    for _arg in "$@"; do
      case "$_arg" in
        *diegonmarcos.com*) _needs_token=1 ;;
        Authorization:*) _has_auth=1 ;;
      esac
    done

    if [ "$_needs_token" = "1" ] && [ "$_has_auth" = "0" ] && [ -f "${tokenFile}" ]; then
      _token=$(${pkgs.jq}/bin/jq -r .access_token "${tokenFile}" 2>/dev/null)
      if [ -n "$_token" ] && [ "$_token" != "null" ]; then
        exec ${realBin} ${headerFlag} "Authorization: Bearer $_token" "$@"
      fi
    fi

    exec ${realBin} "$@"
  '';

in
{
  home.packages = [
    (lib.hiPrio (mkWrapperPkg "curl" realCurl "-H"))
    (lib.hiPrio (mkWrapperPkg "wget" realWget "--header"))
  ];
}
