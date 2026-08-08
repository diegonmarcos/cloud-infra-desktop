#!/bin/sh
# Re-entry guard
if [ "${_CURL_WRAP:-}" = "1" ]; then
  exec @TOOL@ "$@"
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

if [ "$_needs_token" = "1" ] && [ "$_has_auth" = "0" ] && [ -f "@TOKEN_FILE@" ]; then
  _token=$(@JQ_BIN@ -r .access_token "@TOKEN_FILE@" 2>/dev/null)
  if [ -n "$_token" ] && [ "$_token" != "null" ]; then
    exec @TOOL@ @HEADER_FLAG@ "Authorization: Bearer $_token" "$@"
  fi
fi

exec @TOOL@ "$@"
