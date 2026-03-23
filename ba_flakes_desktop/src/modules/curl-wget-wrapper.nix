# curl/wget wrapper: auto-inject Authelia bearer token for *.diegonmarcos.com
# Transparent — all other URLs pass through unmodified.
{ config, lib, pkgs, ... }:

let
  tokenFile = "$HOME/Mounts/Git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/cloud-admin.json";

  # Token check + inject (shared between curl/wget)
  mkWrapper = tool: headerFlag: ''
    #!/bin/sh
    # Re-entry guard
    if [ "''${_CURL_WRAP:-}" = "1" ]; then
      exec ${tool} "$@"
    fi
    export _CURL_WRAP=1
    PATH="$(printf "%s" "$PATH" | tr ':' '\n' | grep -v '\.local/bin' | tr '\n' ':')"

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
        exec ${tool} ${headerFlag} "Authorization: Bearer $_token" "$@"
      fi
    fi

    exec ${tool} "$@"
  '';

in
{
  home.file = {
    ".local/bin/curl" = {
      executable = true;
      text = mkWrapper "curl" "-H";
    };
    ".local/bin/wget" = {
      executable = true;
      text = mkWrapper "wget" "--header";
    };
  };
}
