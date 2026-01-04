#!/bin/bash

# Container entry point
# GUI apps use host's X server via DISPLAY variable

# Start tor daemon in background (optional)
if command -v tor &> /dev/null; then
    sudo tor &> /dev/null &
fi

# Start dnscrypt-proxy in background (optional)
if command -v dnscrypt-proxy &> /dev/null; then
    sudo dnscrypt-proxy &> /dev/null &
fi

exec "$@"
