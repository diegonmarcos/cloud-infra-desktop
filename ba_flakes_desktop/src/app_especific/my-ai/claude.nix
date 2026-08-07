# ai/claude.nix — Claude wrappers
# claude-code itself is delivered as a direct Bun binary by common.nix's
# activation script (Anthropic GCS download + patchelf). This leaf only
# carries the wrapper scripts that tweak NODE_OPTIONS / containers / fallback
# chains around the deployed `claude` command.
{ config, pkgs, lib, ... }:
let
  # claude-rescue: shell body lives in ./claude-rescue.sh. Nothing here was
  # ever Nix-interpolated config (no ports/paths/thresholds baked in) — the
  # extraction is purely the RULE's writeShellScriptBin -> writeShellApplication
  # conversion. `podman`/`npx`/`nix`/`node`/`npm` are DELIBERATELY left off
  # runtimeInputs: this is a fallback chain that must keep working (and keep
  # skipping unavailable methods) exactly as before, so those stay
  # soft-dependencies resolved from the inherited PATH via `command -v`,
  # never forced build inputs. Only coreutils (timeout, mktemp) is mandatory.
  #
  # Secrets: ANTHROPIC_API_KEY is read from the caller's environment only
  # (`"${ANTHROPIC_API_KEY:-}"`) — never written into this script, the JSON
  # data set, or the nix store. No JSON file was introduced for this script.
  claudeRescue = pkgs.writeShellApplication {
    name = "claude-rescue";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./claude-rescue.sh;
  };
in
{
  home.packages = with pkgs; [
    # ── `claude` loader-shim wrapper (survives auto-updates) ────────────────
    # The native installer's auto-updater replaces
    # ~/.local/share/claude/versions/<ver> with unpatched glibc-linked ELFs
    # and SELF-REPAIRS patched binaries (checksum heal) — so the old
    # patchelf-at-activation approach loses every race (3 breakages
    # 2026-06-10..12). Instead: exec the PRISTINE binary through the nix
    # glibc loader. No file mutation → nothing for the updater to repair,
    # works for every future version. ~/.nix-profile/bin precedes
    # ~/.local/bin in PATH, so this wrapper wins resolution.
    # Once programs.nix-ld is live system-wide (host flake,
    # configuration_packages.nix) the shim is redundant but harmless.
    # Tester: `command -v claude` → ~/.nix-profile/bin/claude AND
    # `claude --version` succeeds right after a fresh auto-update.
    (pkgs.writeShellScriptBin "claude" ''
      REAL="$HOME/.local/bin/claude"
      if [ ! -e "$REAL" ]; then
        REAL=$(ls -t "$HOME"/.local/share/claude/versions/* 2>/dev/null | head -1)
      fi
      [ -n "$REAL" ] || { echo "claude binary not found — run claude-rescue" >&2; exit 127; }
      exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 "$REAL" "$@"
    '')

    (pkgs.writeShellScriptBin "claude-termux" ''
      export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=1024"
      exec claude "$@"
    '')
    (pkgs.writeShellScriptBin "claude-malloc" ''
      export MALLOC_ARENA_MAX=2
      export NODE_OPTIONS="--no-node-snapshot --max-old-space-size=2048"
      export CLAUDE_TMP="$HOME/tmp/claude"
      mkdir -p "$CLAUDE_TMP"
      export TMPDIR="$CLAUDE_TMP"
      exec claude "$@"
    '')
    claudeRescue
  ];
}
