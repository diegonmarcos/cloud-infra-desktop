#!/usr/bin/env bash
# claude-superset-setup.sh — ensure `claude` is installed, WITHOUT npm.
#
# Uses Anthropic's NATIVE installer (binaries from downloads.claude.ai) — the
# same thing `curl -fsSL https://claude.ai/install.sh | bash` does — not the npm
# package. Platform-aware + deps-solving:
#
#   nix / termux  → flake-managed (DECLARATIVE) — points you at build.sh switch;
#                   never imperatively mutates a declarative system.
#   deb           → apt-get the downloader if missing, then native install
#   other linux   → ensure a downloader, then native install
#   macos         → native install
#   --shell       → ephemeral nix-shell for TEMPORARY use (no permanent install)
#
# Endpoints are injected by the Nix wrapper from claude-superset.json
# (CAS_SETUP_URL / CAS_SETUP_CHANNEL) — nothing hardcoded here.
set -u
INSTALLER="${CAS_SETUP_URL:-https://claude.ai/install.sh}"
CHANNEL="${CAS_SETUP_CHANNEL:-stable}"
have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '[setup] %s\n' "$*" >&2; }

MODE="install"
case "${1:-}" in --shell|shell) MODE="shell"; shift ;; esac

# ── Already installed? nothing to do ────────────────────────────────────────
if have claude && [ "$MODE" != "shell" ]; then
  say "claude already installed: $(claude --version 2>/dev/null || echo '?')  ($(command -v claude))"
  exit 0
fi

# ── Platform detection (probe the environment, no assumptions) ──────────────
PLATFORM=unknown
case "${PREFIX:-}" in *com.termux*) PLATFORM=termux ;; esac
if [ "$PLATFORM" = unknown ]; then
  if [ -d /nix/store ] && have nix; then PLATFORM=nix
  elif have apt-get; then PLATFORM=deb
  elif [ "$(uname 2>/dev/null)" = Darwin ]; then PLATFORM=macos
  elif [ "$(uname 2>/dev/null)" = Linux ]; then PLATFORM=linux
  fi
fi
say "platform: $PLATFORM"

native_install() {
  say "installing claude via the NATIVE installer (no npm): $INSTALLER [$CHANNEL]"
  if   have curl; then curl -fsSL "$INSTALLER" | bash -s -- "$CHANNEL"
  elif have wget; then wget -qO- "$INSTALLER" | bash -s -- "$CHANNEL"
  else say "no curl/wget — cannot download"; return 1
  fi
}

# ── --shell : ephemeral nix-shell (temporary usage, no permanent install) ───
if [ "$MODE" = "shell" ]; then
  have nix-shell || { say "nix-shell not available on this host"; exit 1; }
  say "ephemeral claude via nix-shell (temporary — installs into ~/.claude for this run)"
  exec nix-shell -p curl bash --run "curl -fsSL '$INSTALLER' | bash -s -- '$CHANNEL' && exec claude $*"
fi

# ── deps solver: ensure a downloader exists ─────────────────────────────────
ensure_downloader() {
  have curl && return 0; have wget && return 0
  say "no downloader — installing curl"
  case "$PLATFORM" in
    deb)    sudo apt-get update -qq && sudo apt-get install -y curl ;;
    termux) pkg install -y curl ;;
    *)      say "install curl or wget manually, then re-run"; return 1 ;;
  esac
}

case "$PLATFORM" in
  nix|termux)
    # Declarative systems — claude is provided by the flake. Imperatively
    # installing here would violate the fully-declarative rule. Guide instead.
    say "$PLATFORM is flake-managed — claude is declarative, don't hand-install."
    say "  permanent : ~/git/unix/<flake>/build.sh switch   (rebuild the flake)"
    say "  temporary : claude-superset setup --shell         (ephemeral nix-shell)"
    exit 0 ;;
  deb|linux|macos)
    ensure_downloader || exit 1
    native_install || exit 1 ;;
  *)
    say "unknown platform — run manually:  curl -fsSL $INSTALLER | bash"
    exit 1 ;;
esac

# ── verify ──────────────────────────────────────────────────────────────────
if have claude; then
  say "OK — claude $(claude --version 2>/dev/null || echo installed) ($(command -v claude))"
elif [ -x "$HOME/.local/bin/claude" ]; then
  say "OK — installed to ~/.local/bin/claude — ensure ~/.local/bin is on PATH"
else
  say "installer finished but 'claude' isn't on PATH — add ~/.local/bin to PATH and re-open your shell"
fi
