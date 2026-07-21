#!/usr/bin/env bash
# lib.sh — shared helpers for the switch-pipeline step scripts.
# Every step sources this. Steps communicate ONLY via files in dist-ci*/
# (toplevel.name is the canonical hand-off) so each step is independently
# runnable: `bash src/scripts/steps/<NN>-<name>.sh` from anywhere.
set -u
STEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$STEPS_DIR/../../.." && pwd)"
ART="$REPO_DIR/dist-ci"
DIFF_DL="$REPO_DIR/dist-ci-diff-dl"
HAVE="$REPO_DIR/dist-ci-have/have-paths.txt"

log()   { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[✗]\033[0m %s\n' "$*" >&2; }

# target_sys — resolve the target store path from the canonical hand-off file
target_sys() {
    [ -f "$ART/toplevel.name" ] || return 1
    printf '/nix/store/%s\n' "$(cat "$ART/toplevel.name")"
}

active_sys() { readlink -f /nix/var/nix/profiles/system; }
