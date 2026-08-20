#!/usr/bin/env bash
# lib.sh — shared helpers for the switch-pipeline step scripts.
# Every step sources this. Steps communicate ONLY via files in dist-ci*/
# (toplevel.name is the canonical hand-off) so each step is independently
# runnable: `bash src/scripts/steps/<NN>-<name>.sh` from anywhere.
set -u
STEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$STEPS_DIR/../../.." && pwd)"
# ART and DIFF_DL are RUNTIME state — downloaded fresh from CI on every run
# (10-fetch-diff.sh does `rm -rf "$DIFF_DL"` first) — so they live in cloud-data,
# not in the repo. While they pointed at $REPO_DIR/dist-ci* every switch dirtied
# tracked files and git reported modifications nobody authored.
#
# HAVE is the opposite and deliberately stays in-tree: it is an INPUT to CI, the
# committed record of what this laptop already has, which ci_build diffs the new
# closure against to produce the small artifact. Runtime state moves out;
# declared state stays.
_cdp="$REPO_DIR/../1_cicd/dist/scripts/cloud-data-paths.sh"
if [ -r "$_cdp" ]; then . "$_cdp"; ART="$(cd_artifact aa_desk-surface)"
else ART="$HOME/.cloud-data-artifacts/aa_desk-surface"; fi
[ -n "${SURFACE_ART_DIR:-}" ] && ART="$SURFACE_ART_DIR"
DIFF_DL="$ART-diff-dl"
HAVE="$REPO_DIR/dist-ci-have/have-paths.txt"
mkdir -p "$ART" 2>/dev/null || true

log()   { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[✗]\033[0m %s\n' "$*" >&2; }

# target_sys — resolve the target store path from the canonical hand-off file
target_sys() {
    [ -f "$ART/toplevel.name" ] || return 1
    printf '/nix/store/%s\n' "$(cat "$ART/toplevel.name")"
}

active_sys() { readlink -f /nix/var/nix/profiles/system; }
