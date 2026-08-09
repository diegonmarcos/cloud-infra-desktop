#!/usr/bin/env bash
# nix-drift — Version drift detection & update script for nix flakes ecosystem
# Tracks custom derivations (claude-code, gemini-cli) and flake inputs (nixpkgs, home-manager)
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

GIT_ROOT="${GIT_ROOT:-$HOME/git}"
UNIX_ROOT="$GIT_ROOT/unix"
CLOUD_ROOT="$GIT_ROOT/cloud"

CACHE_DIR="$HOME/.cache/nix-drift"
CACHE_TTL=3600  # 1 hour

# Flake directories
FLAKE_TERMUX="$UNIX_ROOT/bb_flakes_termux/src"
FLAKE_DESKTOP="$UNIX_ROOT/ba_flakes_desktop/src"
FLAKE_HOST="$UNIX_ROOT/aa_nixos-surface_host/src"
CLOUD_HM="$CLOUD_ROOT/b_infra"

# Cloud VMs with home-manager flakes
CLOUD_VMS=(gcp-proxy gcp-t4 oci-mail oci-analytics oci-apps oci-apps-2)

# ═══════════════════════════════════════════════════════════════════════════
# Logging
# ═══════════════════════════════════════════════════════════════════════════

C_RESET="\033[0m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_CYAN="\033[0;36m"
C_DIM="\033[2m"
C_BOLD="\033[1m"

log_info()  { printf "${C_CYAN}▸${C_RESET} %s\n" "$*" >&2; }
log_ok()    { printf "${C_GREEN}✓${C_RESET} %s\n" "$*" >&2; }
log_warn()  { printf "${C_YELLOW}⚠${C_RESET} %s\n" "$*" >&2; }
log_error() { printf "${C_RED}✗${C_RESET} %s\n" "$*" >&2; }

# ═══════════════════════════════════════════════════════════════════════════
# Prerequisites
# ═══════════════════════════════════════════════════════════════════════════

require_tools() {
  local missing=()
  for tool in curl jq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    exit 1
  fi
}

detect_platform() {
  if [[ -d "/data/data/com.termux.nix" ]]; then
    PLATFORM="termux"
  else
    PLATFORM="desktop"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Caching
# ═══════════════════════════════════════════════════════════════════════════

cache_get() {
  local key="$1"
  local file="$CACHE_DIR/$key"
  if [[ -f "$file" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$file" 2>/dev/null || echo 0) ))
    if [[ $age -lt $CACHE_TTL ]]; then
      cat "$file"
      return 0
    fi
  fi
  return 1
}

cache_set() {
  local key="$1"
  local value="$2"
  mkdir -p "$CACHE_DIR"
  printf '%s' "$value" > "$CACHE_DIR/$key"
}

# ═══════════════════════════════════════════════════════════════════════════
# Version Queries
# ═══════════════════════════════════════════════════════════════════════════

# Get latest version from npm registry
get_latest_npm() {
  local pkg="$1"
  local cache_key="npm_$(echo "$pkg" | tr '/@' '_')"
  local cached
  if cached=$(cache_get "$cache_key"); then
    echo "$cached"
    return
  fi
  local ver
  ver=$(curl -sL "https://registry.npmjs.org/$pkg/latest" | jq -r '.version // empty') || true
  if [[ -n "$ver" ]]; then
    cache_set "$cache_key" "$ver"
    echo "$ver"
  fi
}

# Extract version from a .nix file. Accepts BOTH spellings:
#   version = "X.Y.Z"   (attribute)
#   version ? "X.Y.Z"   (function default arg — what pkgs/claude-code uses)
# Only `=` was matched before, so the termux claude-code pin reported "?" and
# showed as permanently needing an update even at the newest version
# (2026-08-09).
get_nix_version() {
  local file="$1"
  if [[ -f "$file" ]]; then
    { grep -oP 'version\s*[=?]\s*"\K[^"]+' "$file" || true; } | head -1
  fi
}

# Extract primary hash from a .nix file (first hash = "sha256-..." or npmDepsHash)
get_nix_hash() {
  local file="$1"
  if [[ -f "$file" ]]; then
    # Try hash = "sha256-..." first, then npmDepsHash
    local h
    h=$({ grep -oP '^\s*hash\s*=\s*"\K(sha256-[^"]+)' "$file" || true; } | head -1)
    if [[ -z "$h" ]]; then
      h=$({ grep -oP 'npmDepsHash\s*=\s*"\K(sha256-[^"]+)' "$file" || true; } | head -1)
    fi
    echo "${h:-}"
  fi
}

# Get narHash from flake.lock for a given input node
get_lock_narhash() {
  local lockfile="$1"
  local node="$2"
  if [[ -f "$lockfile" ]]; then
    jq -r ".nodes[\"$node\"].locked.narHash // empty" "$lockfile" 2>/dev/null
  fi
}

# Get revision from flake.lock for a given input node
get_lock_rev() {
  local lockfile="$1"
  local node="$2"
  if [[ -f "$lockfile" ]]; then
    jq -r ".nodes[\"$node\"].locked.rev // empty" "$lockfile" 2>/dev/null
  fi
}

# Get lastModified timestamp from flake.lock
get_lock_date() {
  local lockfile="$1"
  local node="$2"
  if [[ -f "$lockfile" ]]; then
    jq -r ".nodes[\"$node\"].locked.lastModified // empty" "$lockfile" 2>/dev/null
  fi
}

# Get the ref (branch) for a flake input
get_lock_ref() {
  local lockfile="$1"
  local node="$2"
  if [[ -f "$lockfile" ]]; then
    jq -r ".nodes[\"$node\"].original.ref // empty" "$lockfile" 2>/dev/null
  fi
}

# Get latest rev for a github flake reference (owner/repo/ref)
get_latest_github_rev() {
  local owner="$1"
  local repo="$2"
  local ref="$3"
  local cache_key="github_${owner}_${repo}_$(echo "$ref" | tr '/' '_')"
  local cached
  if cached=$(cache_get "$cache_key"); then
    echo "$cached"
    return
  fi
  local rev
  rev=$(curl -sL "https://api.github.com/repos/$owner/$repo/commits/$ref" | jq -r '.sha // empty') || true
  if [[ -n "$rev" ]]; then
    cache_set "$cache_key" "$rev"
    echo "$rev"
  fi
}

# Get the installed claude-code version (direct binary in ~/.local/bin)
get_local_claude_version() {
  local bin="$HOME/.nix-profile/bin/claude"  # ~/.local/bin/claude is a shadow claude-fix removes
  if [[ -x "$bin" ]]; then
    "$bin" --version 2>/dev/null | head -1 | sed 's/ .*//' || true
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Data Collection
# ═══════════════════════════════════════════════════════════════════════════

# Result arrays (parallel-safe via temp files)
DRIFT_RESULTS=""

add_result() {
  local pkg="$1" flake="$2" current="$3" latest="$4" type="$5" source="$6" age="${7:-}" hash="${8:-}"
  local status="UP-TO-DATE"
  if [[ "$current" != "$latest" ]] && [[ -n "$current" ]] && [[ -n "$latest" ]]; then
    status="OUTDATED"
  elif [[ -z "$current" ]]; then
    status="UNKNOWN"
  fi
  # JSON line
  printf '{"pkg":"%s","flake":"%s","current":"%s","latest":"%s","status":"%s","type":"%s","source":"%s","age":"%s","hash":"%s"}\n' \
    "$pkg" "$flake" "$current" "$latest" "$status" "$type" "$source" "$age" "$hash"
}

collect_custom_derivations() {
  local tmpdir="$1"

  # claude-code (desktop) — GCS binary
  local cc_desktop_file="$FLAKE_DESKTOP/modules/packages/claude-code.nix"
  if [[ -f "$cc_desktop_file" ]]; then
    local cc_current cc_latest cc_hash
    cc_current=$(get_nix_version "$cc_desktop_file")
    cc_latest=$(get_latest_npm "@anthropic-ai/claude-code")
    cc_hash=$(get_nix_hash "$cc_desktop_file")
    add_result "claude-code" "desktop" "${cc_current:-?}" "${cc_latest:-?}" "gcs-binary" "$cc_desktop_file" "" "$cc_hash"
  fi >> "$tmpdir/results"

  # claude-code (termux) — nix derivation pulls claude-code-linux-arm64 from npm registry,
  # autoPatchelfHook links it against Nix glibc. Source of truth: pkgs/claude-code/default.nix.
  local cc_termux_file="$FLAKE_TERMUX/pkgs/claude-code/default.nix"
  if [[ "$PLATFORM" == "termux" ]] && [[ -f "$cc_termux_file" ]]; then
    local cc_termux_current cc_termux_latest cc_termux_hash
    cc_termux_current=$(get_nix_version "$cc_termux_file")
    cc_termux_latest=$(get_latest_npm "@anthropic-ai/claude-code")
    cc_termux_hash=$(get_nix_hash "$cc_termux_file")
    add_result "claude-code" "termux" "${cc_termux_current:-?}" "${cc_termux_latest:-?}" "npm-tarball" "$cc_termux_file" "" "$cc_termux_hash"
  fi >> "$tmpdir/results"

  # gemini-cli (desktop) — npm tarball
  local gem_file="$FLAKE_DESKTOP/modules/packages/gemini-cli.nix"
  if [[ -f "$gem_file" ]]; then
    local gem_current gem_latest gem_hash
    gem_current=$(get_nix_version "$gem_file")
    gem_latest=$(get_latest_npm "@google/gemini-cli")
    gem_hash=$(get_nix_hash "$gem_file")
    add_result "gemini-cli" "desktop" "${gem_current:-?}" "${gem_latest:-?}" "npm-tarball" "$gem_file" "" "$gem_hash"
  fi >> "$tmpdir/results"

  # cloud-infra-mcp (desktop) — local npm
  local mcp_file="$FLAKE_DESKTOP/modules/packages/cloud-infra-mcp.nix"
  local mcp_pkg="$CLOUD_ROOT/a_solutions/bc-obs_c3-infra-mcp-api/package.json"
  if [[ -f "$mcp_file" ]] && [[ -f "$mcp_pkg" ]]; then
    local mcp_current mcp_latest mcp_hash
    mcp_current=$(get_nix_version "$mcp_file")
    mcp_latest=$(jq -r '.version // empty' "$mcp_pkg" 2>/dev/null)
    mcp_hash=$(get_nix_hash "$mcp_file")
    add_result "cloud-infra-mcp" "desktop" "${mcp_current:-?}" "${mcp_latest:-?}" "local-npm" "$mcp_file" "" "$mcp_hash"
  fi >> "$tmpdir/results"
}

collect_flake_inputs() {
  local tmpdir="$1"

  # Collect from all flake directories
  declare -A flake_dirs
  flake_dirs[termux]="$FLAKE_TERMUX"
  flake_dirs[desktop]="$FLAKE_DESKTOP"
  flake_dirs[host]="$FLAKE_HOST"
  for vm in "${CLOUD_VMS[@]}"; do
    flake_dirs["$vm"]="$CLOUD_HM/nixhm-sudo-$vm/src"
  done

  for flake_name in "${!flake_dirs[@]}"; do
    local flake_dir="${flake_dirs[$flake_name]}"
    local lockfile="$flake_dir/flake.lock"
    [[ -f "$lockfile" ]] || continue

    # Get all input nodes from flake.lock root
    local inputs
    inputs=$(jq -r '.nodes.root.inputs | to_entries[] | .value' "$lockfile" 2>/dev/null) || continue

    for node in $inputs; do
      # Only track nixpkgs and home-manager inputs
      local repo owner ref current_rev latest_rev lock_date age_str age_days display_name short_current short_latest nar_hash
      repo=$(jq -r ".nodes[\"$node\"].original.repo // empty" "$lockfile" 2>/dev/null)
      owner=$(jq -r ".nodes[\"$node\"].original.owner // empty" "$lockfile" 2>/dev/null)

      case "$repo" in
        nixpkgs|home-manager)
          ref=$(get_lock_ref "$lockfile" "$node")
          age_str=""
          current_rev=$(get_lock_rev "$lockfile" "$node")
          lock_date=$(get_lock_date "$lockfile" "$node")
          latest_rev=$(get_latest_github_rev "$owner" "$repo" "${ref:-main}")
          nar_hash=$(get_lock_narhash "$lockfile" "$node")

          if [[ -n "$lock_date" ]]; then
            age_days=$(( ( $(date +%s) - lock_date ) / 86400 ))
            age_str="${age_days}d"
          fi

          display_name="$repo"
          [[ -n "$ref" ]] && display_name="$repo ($ref)"

          short_current="${current_rev:0:7}"
          short_latest="${latest_rev:0:7}"

          add_result "$display_name" "$flake_name" "$short_current" "$short_latest" "flake-input" "$lockfile" "$age_str" "$nar_hash"
          ;;
      esac
    done >> "$tmpdir/results"
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# Nix Package Version Tracking
# ═══════════════════════════════════════════════════════════════════════════

# Extract package attribute names from profile .nix files
# Handles: pkgs.foo, pkgs.python312Packages.bar, customPkgs.foo
extract_nix_packages() {
  local profile_dir="$1"
  [[ -d "$profile_dir" ]] || return

  # Extract pkgs.X patterns, skip comments, writeShellScriptBin, meta, etc.
  grep -hroP '(?<!\w)pkgs\.(?!lib\b|stdenv\b|write\w+\b|mkShell\b|symlinkJoin\b|buildEnv\b|fetchurl\b|callPackage\b|runCommand\b|makeWrapper\b)[\w.]+' \
    "$profile_dir"/*.nix 2>/dev/null \
    | sed 's/^pkgs\.//' \
    | sort -u
}

# Get installed package version from home-manager profile
get_installed_version() {
  local attr="$1"
  # Try nix eval on the current profile's nixpkgs
  local ver
  ver=$(nix eval --raw "nixpkgs#${attr}.version" 2>/dev/null) || true
  echo "${ver:-}"
}

# Get latest package version from unstable nixpkgs
get_unstable_version() {
  local attr="$1"
  local ver
  ver=$(nix eval --raw "nixpkgs/nixos-unstable#${attr}.version" 2>/dev/null) || true
  echo "${ver:-}"
}

collect_nix_packages() {
  local tmpdir="$1"

  # Check cache validity: keyed on nixpkgs rev
  local lockfile="$FLAKE_DESKTOP/flake.lock"
  [[ -f "$lockfile" ]] || return
  local current_rev
  current_rev=$(get_lock_rev "$lockfile" "nixpkgs")
  local nix_cache="$CACHE_DIR/nix-packages-${current_rev:0:7}.json"

  if [[ -f "$nix_cache" ]] && [[ -s "$nix_cache" ]]; then
    cat "$nix_cache" >> "$tmpdir/results"
    return
  fi

  local profile_dir="$FLAKE_DESKTOP/modules/profiles"
  [[ -d "$profile_dir" ]] || return

  local pkg_list
  pkg_list=$(extract_nix_packages "$profile_dir")
  [[ -z "$pkg_list" ]] && return

  log_info "Checking $(echo "$pkg_list" | wc -l) nix packages (cached per nixpkgs rev)..."

  local nix_results=""
  local batch_size=8
  local count=0

  while IFS= read -r attr; do
    [[ -z "$attr" ]] && continue

    # Skip sub-package sets we can't easily eval (e.g. python312Packages.foo)
    # Only check top-level packages for now
    if [[ "$attr" == *.* ]]; then
      continue
    fi

    (
      local current latest
      current=$(nix eval --raw "nixpkgs#${attr}.version" 2>/dev/null) || true
      [[ -z "$current" ]] && exit 0

      # Check if nixos-unstable has a newer version
      local cache_key="nixpkg_unstable_${attr}"
      local cached
      if cached=$(cache_get "$cache_key"); then
        latest="$cached"
      else
        latest=$(nix eval --raw "nixpkgs/nixos-unstable#${attr}.version" 2>/dev/null) || true
        [[ -n "$latest" ]] && cache_set "$cache_key" "$latest"
      fi
      [[ -z "$latest" ]] && exit 0

      add_result "$attr" "desktop" "$current" "$latest" "nixpkgs" "profiles/" "" ""
    ) >> "$tmpdir/nix-batch" &

    count=$((count + 1))
    if (( count % batch_size == 0 )); then
      wait
    fi
  done <<< "$pkg_list"
  wait

  # Merge batch results
  if [[ -f "$tmpdir/nix-batch" ]] && [[ -s "$tmpdir/nix-batch" ]]; then
    cat "$tmpdir/nix-batch" >> "$tmpdir/results"
    # Cache for this nixpkgs rev
    mkdir -p "$CACHE_DIR"
    cp "$tmpdir/nix-batch" "$nix_cache"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# npm Dependency Tracking
# ═══════════════════════════════════════════════════════════════════════════

collect_npm_deps() {
  local tmpdir="$1"

  # Find npm deps list files in both flakes
  local deps_files=()
  [[ -f "$FLAKE_DESKTOP/modules/node-npm-deps-list.nix" ]] && deps_files+=("$FLAKE_DESKTOP/modules/node-npm-deps-list.nix")
  [[ -f "$FLAKE_TERMUX/modules/node-npm-deps-list.nix" ]] && deps_files+=("$FLAKE_TERMUX/modules/node-npm-deps-list.nix")

  [[ ${#deps_files[@]} -eq 0 ]] && return

  # Parse "package-name" = "^version"; from the nix file
  # Extract: name and pinned version spec
  local npm_pkgs=""
  for f in "${deps_files[@]}"; do
    while IFS= read -r line; do
      local name spec
      name=$(echo "$line" | grep -oP '"\K[^"]+(?="\s*=)') || continue
      spec=$(echo "$line" | grep -oP '=\s*"\K[^"]+') || continue
      [[ -z "$name" || -z "$spec" ]] && continue
      # Skip @types/ packages — not interesting for drift
      [[ "$name" == @types/* ]] && continue
      npm_pkgs+="$name=$spec"$'\n'
    done < <(grep -E '^\s+"[^"]+"\s*=\s*"' "$f")
  done

  npm_pkgs=$(echo "$npm_pkgs" | sort -u)
  [[ -z "$npm_pkgs" ]] && return

  local npm_count
  npm_count=$(echo "$npm_pkgs" | grep -c '.' || true)
  log_info "Checking $npm_count npm dependencies..."

  local batch_size=10
  local count=0

  while IFS='=' read -r name spec; do
    [[ -z "$name" ]] && continue

    (
      local latest
      latest=$(get_latest_npm "$name")
      [[ -z "$latest" ]] && exit 0

      # Extract pinned version number from spec (strip ^~>= prefixes)
      local pinned
      pinned=$(echo "$spec" | sed 's/^[\^~>=<]*//')

      # Compare major.minor — if latest major.minor > pinned, it's outdated
      if [[ "$pinned" != "$latest" ]] && [[ "$spec" != "latest" ]]; then
        # Check if the spec range already covers the latest
        # Simple heuristic: if same major and spec starts with ^, it's covered
        local pinned_major latest_major
        pinned_major="${pinned%%.*}"
        latest_major="${latest%%.*}"
        if [[ "$spec" == "^"* ]] && [[ "$pinned_major" == "$latest_major" ]]; then
          # Same major, ^ allows it — up to date
          exit 0
        fi
        add_result "$name" "npm-deps" "$spec" "$latest" "npm-dep" "node-npm-deps-list.nix" "" ""
      fi
    ) >> "$tmpdir/npm-batch" &

    count=$((count + 1))
    if (( count % batch_size == 0 )); then
      wait
    fi
  done <<< "$npm_pkgs"
  wait

  if [[ -f "$tmpdir/npm-batch" ]] && [[ -s "$tmpdir/npm-batch" ]]; then
    cat "$tmpdir/npm-batch" >> "$tmpdir/results"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Rendering
# ═══════════════════════════════════════════════════════════════════════════

render_table() {
  local results_file="$1"
  local filter_outdated="${2:-false}"
  local filter_name="${3:-}"

  # Header
  printf "\n${C_BOLD}%-28s %-14s %-12s %-12s %-11s %-5s %s${C_RESET}\n" \
    "PACKAGE" "FLAKE" "CURRENT" "LATEST" "STATUS" "AGE" "HASH"
  printf "%-28s %-14s %-12s %-12s %-11s %-5s %s\n" \
    "───────────────────────────" "─────────────" "───────────" "───────────" "──────────" "────" "────────────────"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local pkg flake current latest status age hash short_hash
    pkg=$(echo "$line" | jq -r '.pkg')
    flake=$(echo "$line" | jq -r '.flake')
    current=$(echo "$line" | jq -r '.current')
    latest=$(echo "$line" | jq -r '.latest')
    status=$(echo "$line" | jq -r '.status')
    age=$(echo "$line" | jq -r '.age // ""')
    hash=$(echo "$line" | jq -r '.hash // ""')

    # Truncate hash for display: show prefix (sha256-XXXXXXXX...)
    if [[ -z "$hash" ]] || [[ "$hash" == "null" ]]; then
      short_hash="-"
    elif [[ "$hash" == "n/a" ]]; then
      short_hash="n/a"
    elif [[ ${#hash} -gt 16 ]]; then
      short_hash="${hash:0:16}..."
    else
      short_hash="$hash"
    fi

    # Apply filters
    if [[ "$filter_outdated" == "true" ]] && [[ "$status" != "OUTDATED" ]] && [[ "$status" != "STALE" ]]; then
      continue
    fi
    if [[ -n "$filter_name" ]] && [[ "$pkg" != *"$filter_name"* ]]; then
      continue
    fi

    # Color status
    local status_color
    case "$status" in
      UP-TO-DATE) status_color="${C_GREEN}" ;;
      OUTDATED)   status_color="${C_RED}" ;;
      STALE)      status_color="${C_YELLOW}" ;;
      *)          status_color="${C_DIM}" ;;
    esac

    printf "%-28s %-14s %-12s %-12s ${status_color}%-11s${C_RESET} %-5s ${C_DIM}%s${C_RESET}\n" \
      "$pkg" "$flake" "$current" "$latest" "$status" "$age" "$short_hash"
  done < "$results_file"

  echo ""
}

render_json() {
  local results_file="$1"
  local filter_outdated="${2:-false}"
  local filter_name="${3:-}"

  echo "["
  local first=true
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local status
    status=$(echo "$line" | jq -r '.status')
    local pkg
    pkg=$(echo "$line" | jq -r '.pkg')

    if [[ "$filter_outdated" == "true" ]] && [[ "$status" != "OUTDATED" ]]; then
      continue
    fi
    if [[ -n "$filter_name" ]] && [[ "$pkg" != *"$filter_name"* ]]; then
      continue
    fi

    if [[ "$first" == "true" ]]; then
      first=false
    else
      echo ","
    fi
    printf '  %s' "$line"
  done < "$results_file"
  echo ""
  echo "]"
}

# ═══════════════════════════════════════════════════════════════════════════
# Commands
# ═══════════════════════════════════════════════════════════════════════════

RESULTS_CACHE="$CACHE_DIR/last-results.jsonl"

cmd_drift() {
  local json_output=false
  local outdated_only=false
  local filter_name=""
  local cached_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)     json_output=true; shift ;;
      --outdated) outdated_only=true; shift ;;
      --cached)   cached_only=true; shift ;;
      --filter)   filter_name="$2"; shift 2 ;;
      *)          log_error "Unknown flag: $1"; exit 1 ;;
    esac
  done

  # --cached: print last results without network checks
  if [[ "$cached_only" == "true" ]]; then
    if [[ -f "$RESULTS_CACHE" ]] && [[ -s "$RESULTS_CACHE" ]]; then
      local cache_age=$(( $(date +%s) - $(stat -c %Y "$RESULTS_CACHE" 2>/dev/null || echo 0) ))
      local cache_age_human=""
      if [[ $cache_age -lt 3600 ]]; then
        cache_age_human="$(( cache_age / 60 ))m ago"
      elif [[ $cache_age -lt 86400 ]]; then
        cache_age_human="$(( cache_age / 3600 ))h ago"
      else
        cache_age_human="$(( cache_age / 86400 ))d ago"
      fi

      local outdated_count
      outdated_count=$(grep -c '"OUTDATED"\|"STALE"' "$RESULTS_CACHE" || true)
      if [[ "$outdated_count" -gt 0 ]]; then
        printf "${C_YELLOW}▸ nix-drift: %d update(s) available${C_RESET} ${C_DIM}(cached %s)${C_RESET}\n" "$outdated_count" "$cache_age_human"
        if [[ "$json_output" == "true" ]]; then
          render_json "$RESULTS_CACHE" "true" "$filter_name"
        else
          # Compact one-line-per-update format for post-switch display
          while IFS= read -r line; do
            local pkg current latest status
            pkg=$(echo "$line" | jq -r '.pkg')
            current=$(echo "$line" | jq -r '.current')
            latest=$(echo "$line" | jq -r '.latest')
            status=$(echo "$line" | jq -r '.status')
            [[ "$status" != "OUTDATED" && "$status" != "STALE" ]] && continue
            printf "  ${C_DIM}%-24s %s → %s${C_RESET}\n" "$pkg" "$current" "$latest"
          done < "$RESULTS_CACHE"
          printf "${C_DIM}  Run: ./build.sh update${C_RESET}  ${C_DIM}(versions+hashes → commit → sync → switch)${C_RESET}\n"
          printf "${C_DIM}       nix-drift plan --apply${C_RESET}  ${C_DIM}(source edits only)${C_RESET}\n"
        fi
      fi
    fi
    return 0
  fi

  require_tools
  detect_platform

  local tmpdir
  tmpdir=$(mktemp -d)
  touch "$tmpdir/results"
  trap "rm -rf $tmpdir" EXIT

  log_info "Scanning packages and flake inputs..."

  # Collect in parallel: custom derivations + flake inputs (fast)
  collect_custom_derivations "$tmpdir" &
  local pid_custom=$!

  collect_flake_inputs "$tmpdir" &
  local pid_flakes=$!

  # npm deps (parallel batch internally)
  collect_npm_deps "$tmpdir" &
  local pid_npm=$!

  wait "$pid_custom" || true
  wait "$pid_flakes" || true
  wait "$pid_npm" || true

  # Nix packages (slow, cached per nixpkgs rev — runs after flake inputs)
  if [[ "$PLATFORM" == "desktop" ]]; then
    collect_nix_packages "$tmpdir"
  fi

  if [[ ! -s "$tmpdir/results" ]]; then
    log_warn "No results found. Check that git repos exist at $GIT_ROOT"
    return 1
  fi

  # Cache results for --cached flag
  mkdir -p "$CACHE_DIR"
  cp "$tmpdir/results" "$RESULTS_CACHE"

  if [[ "$json_output" == "true" ]]; then
    render_json "$tmpdir/results" "$outdated_only" "$filter_name"
  else
    render_table "$tmpdir/results" "$outdated_only" "$filter_name"

    # Summary
    local total outdated
    total=$(wc -l < "$tmpdir/results")
    outdated=$(grep -c '"OUTDATED"' "$tmpdir/results" || true)
    printf "${C_DIM}%d tracked · %d outdated${C_RESET}\n\n" "$total" "$outdated"
  fi
}

cmd_plan() {
  local dry_run=true
  local filter_pkg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)    dry_run=false; shift ;;
      --dry-run)  dry_run=true; shift ;;
      --package)  filter_pkg="$2"; shift 2 ;;
      *)          log_error "Unknown flag: $1"; exit 1 ;;
    esac
  done

  require_tools
  detect_platform

  local tmpdir
  tmpdir=$(mktemp -d)
  touch "$tmpdir/results"
  trap "rm -rf $tmpdir" EXIT

  log_info "Collecting version data..."
  collect_custom_derivations "$tmpdir"
  collect_flake_inputs "$tmpdir"
  collect_npm_deps "$tmpdir"
  [[ "$PLATFORM" == "desktop" ]] && collect_nix_packages "$tmpdir"

  local plan_file="$CACHE_DIR/plan.json"
  mkdir -p "$CACHE_DIR"
  echo "[]" > "$plan_file"

  local plan_items="[]"
  local has_updates=false

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local pkg status type source current latest
    pkg=$(echo "$line" | jq -r '.pkg')
    status=$(echo "$line" | jq -r '.status')
    type=$(echo "$line" | jq -r '.type')
    source=$(echo "$line" | jq -r '.source')
    current=$(echo "$line" | jq -r '.current')
    latest=$(echo "$line" | jq -r '.latest')
    local flake
    flake=$(echo "$line" | jq -r '.flake')

    [[ "$status" != "OUTDATED" ]] && continue
    [[ -n "$filter_pkg" ]] && [[ "$pkg" != *"$filter_pkg"* ]] && continue

    has_updates=true

    case "$type" in
      gcs-binary)
        log_info "Plan: Update $pkg in $flake ($current → $latest)"
        local nix_file="$source"
        if [[ "$dry_run" == "true" ]]; then
          printf "  ${C_DIM}Would update version in %s${C_RESET}\n" "$nix_file"
          if [[ "$PLATFORM" == "desktop" ]]; then
            printf "  ${C_DIM}Would prefetch new hash via nix-prefetch-url${C_RESET}\n"
          else
            printf "  ${C_YELLOW}⚠ Hash prefetch requires desktop (nix-prefetch-url may OOM on termux)${C_RESET}\n"
          fi
        else
          # Update version in .nix file
          sed -i "s/version = \"$current\"/version = \"$latest\"/" "$nix_file"
          log_ok "Updated version in $nix_file"

          if [[ "$PLATFORM" == "desktop" ]] && command -v nix-prefetch-url >/dev/null 2>&1; then
            local bucket
            bucket=$(grep -oP 'bucket\s*=\s*"\K[^"]+' "$nix_file")
            local url="$bucket/$latest/linux-x64/claude"
            log_info "Prefetching hash for $url..."
            local raw_hash
            raw_hash=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null) || true
            if [[ -n "$raw_hash" ]]; then
              local sri_hash
              sri_hash=$(nix hash to-sri --type sha256 "$raw_hash")
              sed -i "s|hash = \"[^\"]*\"|hash = \"$sri_hash\"|" "$nix_file"
              log_ok "Updated hash to $sri_hash"
            else
              log_warn "Hash prefetch failed — set hash = \"\" and let nix build show correct hash"
              sed -i 's|hash = "[^"]*"|hash = ""|' "$nix_file"
            fi
          else
            # Clear hash so nix build will error with the correct one
            sed -i 's|hash = "[^"]*"|hash = ""|' "$nix_file"
            log_warn "Hash cleared — run nix build on desktop to get correct hash"
          fi
        fi

        plan_items=$(echo "$plan_items" | jq --arg p "$pkg" --arg f "$flake" --arg c "$current" --arg l "$latest" --arg t "$type" --arg s "$source" \
          '. + [{"pkg":$p,"flake":$f,"from":$c,"to":$l,"type":$t,"source":$s,"action":"update-nix-version"}]')
        ;;

      npm-tarball)
        log_info "Plan: Update $pkg in $flake ($current → $latest)"
        local nix_file="$source"
        if [[ "$dry_run" == "true" ]]; then
          printf "  ${C_DIM}Would update version in %s${C_RESET}\n" "$nix_file"
          printf "  ${C_DIM}Would need to regenerate package-lock.json and prefetch npm deps${C_RESET}\n"
        else
          sed -i "s/version = \"$current\"/version = \"$latest\"/" "$nix_file"
          # Clear hashes — user needs to regenerate
          sed -i 's|hash = "sha256-[^"]*"|hash = ""|' "$nix_file"
          sed -i 's|npmDepsHash = "sha256-[^"]*"|npmDepsHash = ""|' "$nix_file"
          log_ok "Updated version, cleared hashes (regenerate with nix build)"
          log_warn "You also need to regenerate gemini-cli-package-lock.json"
        fi

        plan_items=$(echo "$plan_items" | jq --arg p "$pkg" --arg f "$flake" --arg c "$current" --arg l "$latest" --arg t "$type" --arg s "$source" \
          '. + [{"pkg":$p,"flake":$f,"from":$c,"to":$l,"type":$t,"source":$s,"action":"update-npm-tarball"}]')
        ;;

      npm-global)
        log_info "Plan: Update $pkg in $flake ($current → $latest)"
        if [[ "$dry_run" == "true" ]]; then
          printf "  ${C_DIM}Would run: npm install -g @anthropic-ai/claude-code@%s${C_RESET}\n" "$latest"
        else
          log_info "Running: npm install -g @anthropic-ai/claude-code@$latest"
          npm install -g "@anthropic-ai/claude-code@$latest" || log_error "npm install failed"
        fi

        plan_items=$(echo "$plan_items" | jq --arg p "$pkg" --arg f "$flake" --arg c "$current" --arg l "$latest" --arg t "$type" \
          '. + [{"pkg":$p,"flake":$f,"from":$c,"to":$l,"type":$t,"source":"npm-global","action":"npm-install-global"}]')
        ;;

      local-npm)
        log_info "Plan: $pkg — version comes from cloud repo (build.sh ship updates it)"
        if [[ "$current" != "$latest" ]]; then
          printf "  ${C_DIM}Nix derivation version (%s) differs from package.json (%s)${C_RESET}\n" "$current" "$latest"
          printf "  ${C_DIM}Update version in %s to match${C_RESET}\n" "$source"
          if [[ "$dry_run" == "false" ]]; then
            sed -i "s/version = \"$current\"/version = \"$latest\"/" "$source"
            log_ok "Updated version in $source"
          fi
        fi

        plan_items=$(echo "$plan_items" | jq --arg p "$pkg" --arg f "$flake" --arg c "$current" --arg l "$latest" --arg t "$type" --arg s "$source" \
          '. + [{"pkg":$p,"flake":$f,"from":$c,"to":$l,"type":$t,"source":$s,"action":"update-local-version"}]')
        ;;

      flake-input)
        local lockfile="$source"
        local flake_dir
        flake_dir=$(dirname "$lockfile")
        log_info "Plan: Update $pkg in $flake ($current → $latest)"
        if [[ "$dry_run" == "true" ]]; then
          # Determine input name from the node
          local input_name
          input_name=$(echo "$pkg" | grep -oP '^\w[\w-]*' | head -1)
          # Map display name back to flake input name
          case "$pkg" in
            nixpkgs*) input_name="nixpkgs" ;;
            home-manager*) input_name="home-manager" ;;
          esac
          # Check for variant names in the lockfile
          local actual_inputs
          actual_inputs=$(jq -r '.nodes.root.inputs | keys[]' "$lockfile" 2>/dev/null | grep -i "$(echo "$input_name" | tr '-' '.')\|$input_name" || true)
          for inp in $actual_inputs; do
            printf "  ${C_DIM}Would run: nix flake lock --update-input %s  (in %s)${C_RESET}\n" "$inp" "$flake_dir"
          done
        else
          # Find matching inputs in this lockfile
          local actual_inputs
          actual_inputs=$(jq -r '.nodes.root.inputs | to_entries[] | select(.value | test("'"$(echo "$pkg" | sed 's/ .*//')"'"; "i")) | .key' "$lockfile" 2>/dev/null || true)
          if [[ -z "$actual_inputs" ]]; then
            case "$pkg" in
              nixpkgs*) actual_inputs=$(jq -r '.nodes.root.inputs | keys[]' "$lockfile" 2>/dev/null | grep "nixpkgs" || true) ;;
              home-manager*) actual_inputs=$(jq -r '.nodes.root.inputs | keys[]' "$lockfile" 2>/dev/null | grep "home-manager" || true) ;;
            esac
          fi
          for inp in $actual_inputs; do
            log_info "Updating input $inp in $flake_dir..."
            (cd "$flake_dir" && nix flake lock --update-input "$inp") || log_warn "Failed to update $inp in $flake_dir"
          done
        fi

        plan_items=$(echo "$plan_items" | jq --arg p "$pkg" --arg f "$flake" --arg c "$current" --arg l "$latest" --arg t "$type" --arg s "$source" \
          '. + [{"pkg":$p,"flake":$f,"from":$c,"to":$l,"type":$t,"source":$s,"action":"update-flake-input"}]')
        ;;
    esac
  done < "$tmpdir/results"

  if [[ "$has_updates" == "false" ]]; then
    log_ok "Everything is up to date!"
    return 0
  fi

  # Save plan
  echo "$plan_items" | jq '.' > "$plan_file"
  log_ok "Plan saved to $plan_file"

  if [[ "$dry_run" == "true" ]]; then
    printf "\n${C_DIM}Run 'nix-drift plan --apply' to apply changes${C_RESET}\n\n"
  fi
}

cmd_switch() {
  local plan_file="$CACHE_DIR/plan.json"
  if [[ ! -f "$plan_file" ]]; then
    log_error "No plan found. Run 'nix-drift plan --apply' first."
    exit 1
  fi

  local plan
  plan=$(cat "$plan_file")
  local count
  count=$(echo "$plan" | jq 'length')

  if [[ "$count" == "0" ]]; then
    log_ok "Nothing to switch."
    return 0
  fi

  detect_platform

  # Determine which flakes need rebuilding
  local needs_termux=false
  local needs_desktop=false
  local needs_cloud=false

  for i in $(seq 0 $((count - 1))); do
    local flake
    flake=$(echo "$plan" | jq -r ".[$i].flake")
    case "$flake" in
      termux)  needs_termux=true ;;
      desktop) needs_desktop=true ;;
      host)    needs_desktop=true ;;  # host uses desktop build.sh? or its own
      *)       needs_cloud=true ;;
    esac
  done

  if [[ "$needs_termux" == "true" ]]; then
    log_info "Switching termux flake..."
    local build_sh="$UNIX_ROOT/bb_flakes_termux/build.sh"
    if [[ -x "$build_sh" ]]; then
      "$build_sh" switch
    else
      log_warn "build.sh not found at $build_sh"
    fi
  fi

  if [[ "$needs_desktop" == "true" ]]; then
    if [[ "$PLATFORM" == "desktop" ]]; then
      log_info "Switching desktop flake..."
      local build_sh="$UNIX_ROOT/ba_flakes_desktop/build.sh"
      if [[ -x "$build_sh" ]]; then
        "$build_sh" switch
      else
        log_warn "build.sh not found at $build_sh"
      fi
    else
      log_warn "Desktop flake changes require running on desktop"
    fi
  fi

  if [[ "$needs_cloud" == "true" ]]; then
    log_info "Cloud VM changes — commit and push to trigger GHA deploy"
    printf "  ${C_DIM}git -C %s add -A && git commit -m 'nix-drift: update flake inputs'${C_RESET}\n" "$CLOUD_ROOT"
    printf "  ${C_DIM}git -C %s push${C_RESET}\n" "$CLOUD_ROOT"
    read -rp "Commit and push cloud changes? [y/N] " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
      git -C "$CLOUD_ROOT" add -A
      git -C "$CLOUD_ROOT" commit -m "nix-drift: update flake inputs" || log_warn "Nothing to commit"
      git -C "$CLOUD_ROOT" push || log_error "Push failed"
    fi
  fi

  log_ok "Switch complete."
}

cmd_update() {
  log_info "=== nix-drift update: full pipeline ==="
  echo ""

  # Step 1: drift
  log_info "Step 1/3: Checking drift..."
  cmd_drift

  read -rp "Continue to plan? [Y/n] " confirm
  [[ "$confirm" == "n" || "$confirm" == "N" ]] && return 0

  # Step 2: plan --apply
  log_info "Step 2/3: Generating and applying plan..."
  cmd_plan --apply

  read -rp "Continue to switch? [Y/n] " confirm
  [[ "$confirm" == "n" || "$confirm" == "N" ]] && return 0

  # Step 3: switch
  log_info "Step 3/3: Switching..."
  cmd_switch

  log_ok "Update complete!"
}

cmd_clean() {
  if [[ -d "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR"
    log_ok "Cache cleared"
  else
    log_info "No cache to clear"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  printf '%b\n' \
    "${C_BOLD}nix-drift${C_RESET} — Version drift detection for nix flakes ecosystem" \
    "" \
    "${C_BOLD}USAGE${C_RESET}" \
    "  nix-drift <command> [flags]" \
    "" \
    "${C_BOLD}COMMANDS${C_RESET}" \
    "  drift     Show version status of all tracked packages/inputs" \
    "  plan      Compute update plan (--dry-run default, --apply to write)" \
    "  switch    Apply plan via build.sh / git push" \
    "  update    Full pipeline: drift → plan → switch" \
    "  clean     Clear cache" \
    "" \
    "${C_BOLD}FLAGS (drift)${C_RESET}" \
    "  --json        Output as JSON" \
    "  --outdated    Only show outdated entries" \
    "  --cached      Show last cached results (no network, instant)" \
    "  --filter <n>  Filter by package name" \
    "" \
    "${C_BOLD}FLAGS (plan)${C_RESET}" \
    "  --dry-run     Show what would change (default)" \
    "  --apply       Write changes to source files" \
    "  --package <n> Only plan for specific package" \
    "" \
    "${C_BOLD}EXAMPLES${C_RESET}" \
    "  nix-drift drift" \
    "  nix-drift drift --json --outdated" \
    "  nix-drift plan --dry-run" \
    "  nix-drift plan --apply --package claude-code" \
    "  nix-drift update"
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    drift)   cmd_drift "$@" ;;
    plan)    cmd_plan "$@" ;;
    switch)  cmd_switch "$@" ;;
    update)  cmd_update "$@" ;;
    refresh) cmd_drift --outdated >/dev/null 2>&1 ;;
    clean)   cmd_clean ;;
    -h|--help|help|"")
      usage ;;
    *)
      log_error "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
