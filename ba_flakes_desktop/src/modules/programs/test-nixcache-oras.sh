#!/usr/bin/env bash
# test-nixcache-oras.sh — proves the GHCR per-path nix-cache transport wiring
# (2026-07-16) WITHOUT touching the real store or a remote registry: export one
# store path → oras push to a LOCAL oci-layout with a toplevel annotation →
# read the manifest back → assert (a) each layer title carries the store hash so
# the desktop can map layer→path, (b) the toplevel annotation round-trips, and
# (c) a fetched blob is a valid nix `--export` stream. This is the read side of
# nixcache_switch; a full switch is exercised live against GHCR.
set -uo pipefail
CFG="${1:-$(dirname "$0")/../nix-cache.json}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
oras() { nix run --extra-experimental-features "nix-command flakes" nixpkgs#oras -- "$@"; }

ANN="$(jq -r '.toplevel_annotation' "$CFG")"; MT="$(jq -r '.blob_media_type' "$CFG")"
[ -n "$ANN" ] && [ "$ANN" != null ] || fail "toplevel_annotation missing in $CFG"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W"
P="$(nix path-info /nix/store/*-coreutils-* 2>/dev/null | head -1)"
[ -n "$P" ] || P="$(ls -d /nix/store/*-bash-* 2>/dev/null | head -1)"
[ -n "$P" ] || fail "no test store path found"
H="$(basename "$P")"; H="${H%%-*}"
mkdir -p blobs
nix-store --export "$P" | zstd -q -o "blobs/${H}.zst" || fail "export failed"

oras push --annotation "${ANN}=some-toplevel-name" \
  --oci-layout "$W/reg:t" "blobs/${H}.zst:$MT" >/dev/null 2>&1 || fail "oras push"

MAN="$(oras manifest fetch --oci-layout "$W/reg:t" 2>/dev/null)" || fail "manifest fetch"
title="$(jq -r '.layers[0].annotations["org.opencontainers.image.title"]' <<<"$MAN")"
[ "$title" = "blobs/${H}.zst" ] || fail "layer title lost store hash (got '$title')"
pass "layer title carries store hash ($H)"
top="$(jq -r --arg k "$ANN" '.annotations[$k] // empty' <<<"$MAN")"
[ "$top" = "some-toplevel-name" ] || fail "toplevel annotation did not round-trip (got '$top')"
pass "toplevel annotation round-trips via '$ANN'"
dg="$(jq -r '.layers[0].digest' <<<"$MAN")"
# oci-layout blob target is "<path>@<digest>" (registry form is "<ref>@<digest>",
# exactly what nixcache_switch uses). Fetch to a file, not a truncating pipe.
oras blob fetch --oci-layout --output "$W/out.zst" "$W/reg@${dg}" >/dev/null 2>&1 || fail "blob fetch"
magic="$(zstd -dq -c "$W/out.zst" | head -c1 | od -An -tu1 | tr -d ' ')"
[ "$magic" = "1" ] || fail "fetched blob is not a nix --export stream (first byte '$magic', want 1)"
pass "fetched blob is a valid nix --export stream"
echo "ALL PASS: GHCR per-path nixcache transport wiring is sound"
