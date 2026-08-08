# curl/wget wrapper: auto-inject Authelia bearer token for *.diegonmarcos.com
# Transparent — all other URLs pass through unmodified.
{ config, lib, pkgs, ... }:

let
  tokenFile = "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens/cloud-admin.json";

  # Token check + inject (shared between curl/wget)
  mkWrapper = tool: headerFlag:
    builtins.replaceStrings
      [ "@TOOL@" "@HEADER_FLAG@" "@JQ_BIN@"            "@TOKEN_FILE@" ]
      [ tool     headerFlag      "${pkgs.jq}/bin/jq"   tokenFile      ]
      (builtins.readFile ./scripts/curl-wget-wrapper.sh);

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
