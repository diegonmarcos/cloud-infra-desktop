#!/usr/bin/env bash
export WHITELIST_JSON="${WHITELIST_JSON:-$HOME/.config/orphan-reaper/whitelist.json}"
exec @enginePath@ "$@"
