#!/usr/bin/env bash
if [ ! -r "@secretFile@" ]; then
  echo "[wstunnel] ERROR: @secretFile@ not found." >&2
  echo "[wstunnel] sops-decrypt the WSTUNNEL_PATH_PREFIX secret first." >&2
  exit 1
fi
