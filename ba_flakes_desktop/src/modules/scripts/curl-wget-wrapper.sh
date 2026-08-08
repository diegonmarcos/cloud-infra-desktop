#!/usr/bin/env bash
# Re-entry guard
if [ "${_CURL_WRAP:-}" = "1" ]; then
  exec @realBin@ "$@"
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

if [ "$_needs_token" = "1" ] && [ "$_has_auth" = "0" ] && [ -f "@tokenFile@" ]; then
  _token=$(@jq@ -r .access_token "@tokenFile@" 2>/dev/null)
  if [ -n "$_token" ] && [ "$_token" != "null" ]; then
    exec @realBin@ @headerFlag@ "Authorization: Bearer $_token" "$@"
  fi
fi

exec @realBin@ "$@"
