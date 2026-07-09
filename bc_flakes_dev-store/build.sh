#!/usr/bin/env bash
# bc_flakes_dev-store engine — build the heavy dev toolchain into a p5 CHROOT store.
#
# The dev profile is the `devProfile` package output of the DESKTOP flake
# (ba_flakes_desktop/src) — defined there to reuse its pkgs overlays + inputs and
# the SAME leaf modules the pool imports (DRY). We realise it with `--store
# local?root=/mnt/shared-lib/dev-store&store=/nix/store`: storeDir stays /nix/store
# (so cache.nixos.org substitutes — no rebuild-world) but the bytes land on p5,
# NEVER the <7G-free pool. The `dev` bwrap launcher then binds that store over
# /nix/store. Config: build.json. Plan: ../0_tasks/PLAN_dev-store-split.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$SCRIPT_DIR/build.json"
# build.sh is the sanctioned interface — skip the interactive guardrail wrappers.
export BUILDSH_GUARDRAIL=1
# Array (not a string) so the two-word feature value stays ONE argument — a plain
# string word-splits and `flakes` is read as a bogus flake installable.
NIXFLAGS=(--extra-experimental-features "nix-command flakes" --impure)

die() { echo "[dev-store] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need jq; need nix

j() { jq -r "$1" "$CFG"; }
STORE_URI="$(j .store_uri)"
P5_ROOT="$(j .p5_root)"
GCROOT="$(j .profile_gcroot)"
GC_KEEP="$(j .gc_keep)"
# flake_ref in build.json is "<relative-flake-dir>#<attr>" relative to this script
# dir → resolve the flake DIR to absolute (no dirname — the path part IS the dir).
FLAKE_REL="$(j .flake_ref)"
FLAKE_PATH="${FLAKE_REL%#*}"
FLAKE_ATTR="${FLAKE_REL#*#}"
FLAKE_DIR="$(cd "$SCRIPT_DIR/$FLAKE_PATH" && pwd)" || die "flake dir not found: $SCRIPT_DIR/$FLAKE_PATH"
FLAKE_REF="$FLAKE_DIR#$FLAKE_ATTR"
CACHE_IMG="$(j .cache_image)"
CACHE_IMG_REL="$(j .cache_image_attr)"
CACHE_IMG_PATH="${CACHE_IMG_REL%#*}"
CACHE_IMG_ATTR="${CACHE_IMG_REL#*#}"
CACHE_IMG_DIR="$(cd "$SCRIPT_DIR/$CACHE_IMG_PATH" && pwd)" || die "cache-image flake dir not found: $SCRIPT_DIR/$CACHE_IMG_PATH"
CACHE_IMG_REF="$CACHE_IMG_DIR#$CACHE_IMG_ATTR"

preflight() {
  [ -d "$P5_ROOT" ] || die "$P5_ROOT does not exist — apply the NixOS host tmpfiles rule first (build.sh switch on aa_desk-usr…)."
  [ -w "$P5_ROOT" ] || die "$P5_ROOT not writable by $(id -un) — check the tmpfiles owner (diego users)."
  # The desktop flake stages dirty files itself on switch; for a pure build we just
  # bust the eval cache so a freshly-edited leaves.json/devProfile is seen.
  touch "$FLAKE_DIR/flake.nix" 2>/dev/null || true
}

cmd_build() {   # copy the devProfile closure into p5 (local disk-to-disk, no re-download)
  preflight
  echo "[dev-store] building devProfile (tiny buildEnv; closure already local) + copying to p5…"
  # `nix copy` builds the buildEnv into the local/pool store (the 25G closure is
  # already there) and copies the closure to the p5 chroot store FROM the local
  # store — no network, no pool growth (only a ~MB symlink-tree output).
  nix copy "${NIXFLAGS[@]}" --no-check-sigs --to "$STORE_URI" "$FLAKE_REF"
}

cmd_link() {    # copy + register the p5 profile gcroot the `dev` launcher reads
  cmd_build
  echo "[dev-store] registering p5 gcroot $GCROOT…"
  # p5 now holds the closure (from cmd_build) → this only builds the gcroot link,
  # no download.
  nix build "${NIXFLAGS[@]}" --store "$STORE_URI" "$FLAKE_REF" -o "$GCROOT"
  echo "[dev-store] gcroot: $GCROOT -> $(readlink "$GCROOT" 2>/dev/null || echo '?')"
}

cmd_gc() {      # collect the p5 store (the gcroot pins the current profile)
  echo "[dev-store] gc p5 store (keep current profile gcroot)…"
  nix store gc "${NIXFLAGS[@]}" --store "$STORE_URI"
}

cmd_status() {
  echo "=== dev-store profile (p5) ==="
  if [ -e "$GCROOT" ]; then
    nix path-info "${NIXFLAGS[@]}" --store "$STORE_URI" -S "$GCROOT" 2>/dev/null \
      | awk '{printf "  closure %.2f GiB  %s\n", $2/1073741824, $1}'
  else
    echo "  (no profile linked yet — run: build.sh ship)"
  fi
  echo "=== p5 disk ==="; df -h "$P5_ROOT" 2>/dev/null | tail -1
  echo "=== pool /nix ==="; df -h /nix 2>/dev/null | tail -1
}

cmd_ship() { cmd_link; cmd_status; }

# ci-build — run on a GHA x86 runner. Build devProfile into the RUNNER store and
# export its full closure as a zstd tarball artifact. The 8GB Surface can't eval
# the heavy toolchain locally without thrashing (same freeze axis as desktop_nixos
# / _hm) — so the eval+realise happens on GHA; the laptop only imports (cmd_pull).
cmd_ci_build() {
  local out="$SCRIPT_DIR/dist-ci"
  rm -rf "$out"; mkdir -p "$out"
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "[dev-store] freeing GHA runner disk…"
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
                /opt/hostedtoolcache/CodeQL /usr/local/share/boost 2>/dev/null || true
  fi
  echo "[dev-store] building $FLAKE_REF on runner (cache.nixos.org substitutes)…"
  nix build "${NIXFLAGS[@]}" --accept-flake-config "$FLAKE_REF" --out-link "$out/result" -L \
    || die "ci build failed"
  local sys; sys="$(readlink -f "$out/result")"
  basename "$sys" > "$out/devprofile.name"
  echo "[dev-store] exporting closure → zstd tarball…"
  nix-store --export $(nix-store -qR "$sys") | zstd -T0 -15 > "$out/devstore-closure.nar.zst"
  rm -f "$out/result"
  echo "[dev-store] done: $(du -h "$out/devstore-closure.nar.zst" | cut -f1) → $out/"

  # ── Stage 1: layered GHCR cache (INCREMENTAL delivery) ──────────────────
  # Additive + NON-FATAL: the nar.zst above stays the active mechanism until
  # pull learns to consume this. Build a layered image of the SAME devProfile
  # closure (one layer per store path) and skopeo-copy it to GHCR — skopeo
  # skips blobs already present in the registry, so only changed layers
  # upload. Guarded by GHCR_PUSH=1 (set by the ship workflow, which holds
  # packages:write + GITHUB_TOKEN). A failure here never fails the closure export.
  if [ "${GHCR_PUSH:-0}" = "1" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "[dev-store] building + pushing layered dev-store cache image -> ${CACHE_IMG}:latest (incremental)"
    # GHA Ubuntu runners ship /etc/containers/registries.conf as legacy v1,
    # which skopeo 1.23 refuses ("must be in v2 format"). Empty v2 config —
    # fully-qualified refs need no registries.
    local reg="$out/registries.conf"
    printf 'unqualified-search-registries = []\n' > "$reg"
    if nix build "${NIXFLAGS[@]}" --accept-flake-config "$CACHE_IMG_REF" --out-link "$out/cache-image"; then
      CONTAINERS_REGISTRIES_CONF="$reg" \
      nix run "${NIXFLAGS[@]}" nixpkgs#skopeo -- \
          copy --dest-creds "x:${GITHUB_TOKEN}" \
          "docker-archive:$(readlink -f "$out/cache-image")" \
          "docker://${CACHE_IMG}:latest" \
          && echo "[dev-store] pushed layered dev-store cache -> ${CACHE_IMG}:latest" \
          || echo "[dev-store] WARN: skopeo push failed (non-fatal — nar.zst artifact still delivered)"
    else
      echo "[dev-store] WARN: dev-store-cache-image build failed (non-fatal — nar.zst still delivered)"
    fi
    rm -f "$out/cache-image"
  fi
}

# ghcr_pull_layered <image:tag> — try to materialise a layered GHCR closure
# image's /nix/store paths onto the p5 chroot store, skipping any path
# already present (genuine incremental — unchanged layers are never even
# pulled by `docker pull`, and unchanged store paths are never re-copied
# locally either). Returns 1 (silently, caller falls back) on ANY failure:
# docker missing, image missing, pull failure — additive, never fatal.
# Populated by `dev-store-cache-image` (ba_flakes_desktop/src/flake.nix) +
# the skopeo push in cmd_ci_build above.
ghcr_pull_layered() {
  local img="$1"
  command -v docker >/dev/null 2>&1 || return 1
  echo "[dev-store] trying layered GHCR pull: $img …"
  docker pull "$img" >/dev/null 2>&1 || { echo "[dev-store] WARN: GHCR image unavailable — falling back to nar.zst"; return 1; }

  local tmp="dev-store-cache-extract-$$"
  docker create --name "$tmp" "$img" >/dev/null 2>&1 || { echo "[dev-store] WARN: docker create failed — falling back to nar.zst"; return 1; }

  local copied=0 skipped=0
  # buildLayeredImage roots the closure at /nix/store inside the image —
  # list it via a throwaway inspect run, then `docker cp` only the missing
  # store paths, importing them into the p5 chroot store (STORE_URI), NOT
  # the pool.
  for p in $(docker run --rm "$img" sh -c 'ls /nix/store' 2>/dev/null); do
    if nix path-info "${NIXFLAGS[@]}" --store "$STORE_URI" "/nix/store/$p" >/dev/null 2>&1; then
      skipped=$((skipped + 1))
      continue
    fi
    if docker cp "$tmp:/nix/store/$p" - 2>/dev/null | nix-store --import --store "$STORE_URI" >/dev/null 2>&1; then
      copied=$((copied + 1))
    fi
  done
  docker rm "$tmp" >/dev/null 2>&1 || true
  echo "[dev-store] layered pull: $copied copied, $skipped already present"
  [ "$copied" -gt 0 ] || [ "$skipped" -gt 0 ]
}

# pull [artifact-dir] — run on the Surface. Import the GHA-built devProfile closure
# DIRECTLY into the p5 CHROOT store (--store STORE_URI → bytes land on p5, the <7G
# pool is never touched) and register the gcroot the `dev` launcher reads. NO eval,
# NO build → cannot freeze. Default artifact-dir is dist-ci/ (after gh run download).
cmd_pull() {
  preflight
  local art="${1:-$SCRIPT_DIR/dist-ci}"
  local tb="$art/devstore-closure.nar.zst"
  local sys=""
  [ -f "$art/devprofile.name" ] && sys="/nix/store/$(cat "$art/devprofile.name")"

  # ── Try GHCR-layered pull first (incremental) ──────────────────────────
  if [ -n "$sys" ] && ghcr_pull_layered "${CACHE_IMG}:latest"; then
    echo "[dev-store] closure materialised via layered GHCR pull."
  else
    [ -f "$tb" ] || die "no closure tarball at $tb (fetch first: gh run download -n nixos-dev-store-closure -D '$art')"
    [ -f "$art/devprofile.name" ] || die "missing $art/devprofile.name"
    sys="/nix/store/$(cat "$art/devprofile.name")"
    echo "[dev-store] importing closure into p5 chroot store ($STORE_URI) — no build…"
    zstd -d -c "$tb" | nix-store --import --store "$STORE_URI" >/dev/null || die "import failed"
  fi
  echo "[dev-store] registering p5 gcroot $GCROOT (no eval)…"
  nix-store "${NIXFLAGS[@]}" --store "$STORE_URI" --realise "$sys" --add-root "$GCROOT" --indirect >/dev/null \
    || die "gcroot registration failed"
  cmd_status
}

case "${1:-status}" in
  build)            cmd_build ;;
  link)             cmd_link ;;
  ship)             cmd_ship ;;
  ci-build|ci_build) cmd_ci_build ;;
  pull)             cmd_pull "${2:-}" ;;
  gc)               cmd_gc ;;
  status)           cmd_status ;;
  *) echo "usage: $0 {build|link|ship|ci-build|pull|gc|status}"; exit 2 ;;
esac
