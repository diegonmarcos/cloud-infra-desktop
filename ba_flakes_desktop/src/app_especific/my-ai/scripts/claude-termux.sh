#!/usr/bin/env bash
# NOTE: also provided by the my-ai binary self-extract (~/.local/bin); redundant, removal deferred.
export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=1024"
exec claude "$@"
