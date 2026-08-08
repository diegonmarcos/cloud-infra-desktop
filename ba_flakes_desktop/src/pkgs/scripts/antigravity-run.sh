#!/usr/bin/env bash
"@unpacked@/opt/antigravity/antigravity" "$@"
rc=$?
pkill -9 -f "@unpacked@/opt/antigravity" 2>/dev/null || true
exit $rc
