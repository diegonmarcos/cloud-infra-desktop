# nix-command-catcher.sh — generated from configuration_nix-command-catcher.nix,
# do not edit by hand. Shared by both the `nix` and `nixos-rebuild` wrappers.
#
# Fully runtime-data-driven: the heavy-verb allowlist is read from
# nix-command-catcher.json (/etc/cloud-data/nix-command-catcher.json) via jq
# at RUNTIME. Nothing is baked in by Nix interpolation. See
# configuration_nix-command-catcher.nix for how this script is wired
# (writeShellApplication + environment.etc deploy of the JSON) and
# nix-command-catcher.json for the verb lists + rationale.
#
# REAL is supplied via $CATCHER_REAL, an environment variable set by the Nix
# module (writeShellApplication's runtimeEnv) to the absolute store path of
# the real binary (nix or nixos-rebuild). VERBS_KEY selects which JSON array
# to read (heavy_nix_verbs or heavy_nixos_rebuild_verbs). Neither must ever
# be resolved with `command -v` or a bare PATH lookup here: this wrapper
# shadows its own name on PATH via lib.hiPrio, so a PATH lookup from inside
# the wrapper would recurse into itself instead of reaching the real binary.
set -u

REAL="${CATCHER_REAL:?nix-command-catcher.sh: CATCHER_REAL not set by Nix module}"
VERBS_KEY="${CATCHER_VERBS_KEY:?nix-command-catcher.sh: CATCHER_VERBS_KEY not set by Nix module}"

# Recursion guard: once inside a catcher-spawned invocation, go straight
# to the real binary — never re-enter this wrapper.
if [ -n "${NSP_ACTIVE:-}" ]; then
  exec "$REAL" "$@"
fi

CONFIG_JSON="${CATCHER_CONFIG_JSON:-/etc/cloud-data/nix-command-catcher.json}"

# If the config is missing or unparseable, this wrapper must never break
# `nix`/`nixos-rebuild` — fall through to the real binary bare rather than
# exiting non-zero. This is a user-facing command interception, exactly
# like home-manager-command-catcher.sh: failing loudly here would break
# every `nix`/`nixos-rebuild` invocation on this machine.
HEAVY_VERBS=()
if [ -r "$CONFIG_JSON" ] && jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  while IFS= read -r v; do
    HEAVY_VERBS+=("$v")
  done < <(jq -r --arg key "$VERBS_KEY" '.[$key][]' "$CONFIG_JSON" 2>/dev/null)
else
  exec "$REAL" "$@"
fi

# First non-flag argument is the verb we gate on.
verb=""
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
    *) verb="$arg"; break ;;
  esac
done

is_heavy=0
for v in "${HEAVY_VERBS[@]:-}"; do
  if [ "$verb" = "$v" ]; then
    is_heavy=1
    break
  fi
done

if [ "$is_heavy" -ne 1 ]; then
  exec "$REAL" "$@"
fi

# NSP_ACTIVE must stay UNSET here. nix-switch-progress-wrap keys its
# whole mode off it: unset on entry = "owner mode", open the progress
# window and drive it; already set = "nested mode", assume an outer
# wrap already owns a window and just exec the command bare. Exporting
# it before the exec below therefore made the wrap open NOTHING, so
# every heavy `nix`/`nixos-rebuild` caught here ran with zero UI — the
# exact "dashboard never launches" symptom this module exists to fix.
# The wrap exports it itself for everything it spawns, and recursion is
# already impossible on this path because we hand it "$REAL" — an
# absolute store path — never a PATH lookup of the wrapper's own name.
if command -v nix-switch-progress-wrap >/dev/null 2>&1 \
  && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  exec nix-switch-progress-wrap "$REAL" "$@"
fi

# Headless or catcher not installed: no window, never block. Here the
# guard IS needed — nothing downstream sets it, and the real binary may
# re-enter this wrapper through a child process's PATH.
export NSP_ACTIVE=1
exec "$REAL" "$@"
