#!/usr/bin/env bash
# getconf shim for third-party tooling (wrangler etc.) on nix-on-droid.
# Unknown variables FAIL (exit 1) like real getconf — the old `echo ""` +
# exit 0 handed callers like PATH="$(getconf PATH)" an empty PATH
# (2026-08-08 audit).
case "${1:-}" in
  LONG_BIT)          echo 64 ;;
  PAGE_SIZE|PAGESIZE) echo 4096 ;;
  _NPROCESSORS_ONLN|_NPROCESSORS_CONF) nproc 2>/dev/null || echo 1 ;;
  ARG_MAX)           echo 2097152 ;;
  PATH)              echo "/usr/bin:/bin" ;;
  *) echo "getconf: unknown variable: ${1:-}" >&2; exit 1 ;;
esac
