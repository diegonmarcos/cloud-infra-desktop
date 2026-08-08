#!/usr/bin/env bash
set -eu
PATH_PREFIX="$(cat "@secretFile@")"
exec @wstunnelBin@ client \
  --local-to-remote 'udp://@localUdp@:127.0.0.1:@remoteWg@' \
  --restrict-http-upgrade-path-prefix "$PATH_PREFIX" \
  '@wsEndpoint@'
