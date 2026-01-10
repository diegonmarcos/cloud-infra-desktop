{
  description = "Portable Claude Code with Sandbox";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      claude = pkgs.writeShellScriptBin "claude" ''
        show_help() {
          cat << 'HELP'
╔═══════════════════════════════════════════════════════════════════╗
║                     CLAUDE CODE CONTAINER                         ║
║                   Portable Sandboxed Environment                  ║
╚═══════════════════════════════════════════════════════════════════╝

USAGE
    claude [OPTIONS] [CLAUDE_ARGS...]

OPTIONS
    -h, --help       Show this help message
    -i, --isolated   Run in isolated sandbox (default)
    -m, --mirror     Run with full home access (no isolation)

MODES
    Isolated (default)
        Claude runs inside a bwrap sandbox with restricted access.
        Only specific directories are mounted:
          • ~/.claude      (read/write)
          • ~/.config      (read/write)
          • ~/.npm-global  (read/write)
          • ~/mnt_git      (read/write)
          • ~/.ssh         (read-only)
          • ~/.gitconfig   (read-only)

    Mirror
        Claude runs with full access to your home directory.
        No isolation - use for trusted operations.

EXAMPLES
    claude                     Run in isolated mode (default)
    claude -i                  Run in isolated mode
    claude -m                  Run in mirror mode
    claude -m .                Mirror mode in current directory
    claude -- --version        Pass --version to Claude

ENVIRONMENT
    CLAUDE_SANDBOXED=1         Set automatically in isolated mode

HELP
          exit 0
        }

        MODE="isolated"
        CLAUDE_ARGS=()

        while [[ $# -gt 0 ]]; do
          case "$1" in
            -h|--help)
              show_help
              ;;
            -i|--isolated)
              MODE="isolated"
              shift
              ;;
            -m|--mirror)
              MODE="mirror"
              shift
              ;;
            *)
              CLAUDE_ARGS+=("$1")
              shift
              ;;
          esac
        done

        export NPM_CONFIG_PREFIX="$HOME/.npm-global"
        mkdir -p "$NPM_CONFIG_PREFIX"

        CLAUDE_BIN="$HOME/.npm-global/bin/claude"
        if [ ! -x "$CLAUDE_BIN" ]; then
          echo "Installing Claude Code..."
          ${pkgs.nodejs_22}/bin/npm install -g @anthropic-ai/claude-code
        fi

        if [ "$MODE" = "mirror" ]; then
          # Mirror mode - no isolation
          export PATH="${pkgs.lib.makeBinPath [ pkgs.nodejs_22 pkgs.git pkgs.coreutils ]}:$HOME/.npm-global/bin:$PATH"
          exec "$CLAUDE_BIN" "''${CLAUDE_ARGS[@]}"
        else
          # Isolated mode (default)
          SANDBOX_TMP="/tmp/claude-sandbox-$$"
          mkdir -p "$SANDBOX_TMP"
          trap "rm -rf $SANDBOX_TMP" EXIT

          exec ${pkgs.bubblewrap}/bin/bwrap \
            --ro-bind /nix /nix \
            --ro-bind /usr /usr \
            --ro-bind /lib /lib \
            --ro-bind /lib64 /lib64 \
            --ro-bind /bin /bin \
            --ro-bind /sbin /sbin \
            --ro-bind /etc/resolv.conf /etc/resolv.conf \
            --ro-bind /etc/hosts /etc/hosts \
            --ro-bind /etc/ssl /etc/ssl \
            --ro-bind /etc/ca-certificates /etc/ca-certificates \
            --ro-bind /etc/passwd /etc/passwd \
            --ro-bind /etc/group /etc/group \
            --setenv SSL_CERT_FILE "/etc/ssl/certs/ca-certificates.crt" \
            --setenv NODE_EXTRA_CA_CERTS "/etc/ssl/certs/ca-certificates.crt" \
            --bind "$HOME/.claude" "$HOME/.claude" \
            --bind "$HOME/.config" "$HOME/.config" \
            --bind "$HOME/.npm-global" "$HOME/.npm-global" \
            --bind "$HOME/mnt_git" "$HOME/mnt_git" \
            --ro-bind "$HOME/.gitconfig" "$HOME/.gitconfig" \
            --ro-bind "$HOME/.ssh" "$HOME/.ssh" \
            --proc /proc \
            --dev /dev \
            --tmpfs /tmp \
            --bind "$SANDBOX_TMP" /tmp \
            --setenv HOME "$HOME" \
            --setenv USER "$USER" \
            --setenv PATH "${pkgs.lib.makeBinPath [ pkgs.nodejs_22 pkgs.git pkgs.coreutils ]}:$HOME/.npm-global/bin" \
            --setenv TERM "$TERM" \
            --setenv LANG "$LANG" \
            --setenv CLAUDE_SANDBOXED "1" \
            --unshare-pid \
            --die-with-parent \
            --new-session \
            "$CLAUDE_BIN" "''${CLAUDE_ARGS[@]}"
        fi
      '';

    in {
      packages.${system}.default = claude;
    };
}
