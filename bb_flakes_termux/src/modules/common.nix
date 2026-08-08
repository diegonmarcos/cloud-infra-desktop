# Common configuration for Termux / nix-on-droid
{ config, pkgs, lib, ... }:

{
  imports = [
    ./programs/shells/bash.nix
    ./programs/shells/fish.nix
    ./programs/shells/starship.nix
    ./programs/editors/vim.nix
    ./programs/git.nix
    ./programs/tmux.nix
  ];

  programs.home-manager.enable = true;

  # Authelia OIDC — paths to vault credentials + tokens
  home.sessionVariables = {
    AUTHELIA_OIDC_CREDENTIALS_DIR = "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/credentials";
    AUTHELIA_OIDC_TOKENS_DIR = "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens";
    AUTHELIA_OIDC_CLIENT_ID = "claude-admin";
    AUTHELIA_TOKEN_URL = "https://auth.diegonmarcos.com/api/oidc/token";
  };

  nix = {
    package = pkgs.nix;
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      warn-dirty = false;
      # No build-dep pinning — termux doesn't build, GHA does.
      keep-outputs = false;
      keep-derivations = false;
    };
  };

  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
    PAGER = "less";
    LESS = "-R -F -X";

    # Octocode — OpenAI-compatible endpoint (Ollama on oci-apps)
    OPENAI_BASE_URL = "http://10.0.0.6:11435/v1";
    OPENAI_API_KEY = "sk-dummy";
  };

  # HM always wins — remove imperative nix profile packages that conflict
  home.activation.removeImperativePackages = lib.hm.dag.entryBefore ["installPackages"] ''
    if command -v nix >/dev/null 2>&1 && nix profile list >/dev/null 2>&1; then
      for pkg in $(nix profile list 2>/dev/null | grep "^Name:" | sed 's/.*Name:[[:space:]]*//' | sed 's/\x1b\[[0-9;]*m//g'); do
        echo "[hm] Removing imperative nix profile package: $pkg"
        nix profile remove "$pkg" 2>/dev/null || true
      done
    fi
  '';

  # Generation trim on every switch, but full GC only under DISK PRESSURE.
  # nix-collect-garbage on every switch was the hidden performance killer:
  # deleting thousands of just-orphaned store paths evicts the kernel page
  # cache, so every warm binary (claude, node, tsx) cold-starts from flash
  # through proot afterwards — measured 11s directory lookups and a 4-minute
  # claude first-start right after a 5156-path GC (2026-08-08). Keeping the
  # 2 newest generations also preserves instant rollback.
  home.activation.trimGenerations = lib.hm.dag.entryAfter [ "installPackages" ] ''
    export PATH="${pkgs.nix}/bin:$PATH"
    $DRY_RUN_CMD nix-env -p /nix/var/nix/profiles/nix-on-droid --delete-generations +2 2>/dev/null || true
    $DRY_RUN_CMD nix-env -p "$HOME/.local/state/nix/profiles/home-manager" --delete-generations +2 2>/dev/null || true
    $DRY_RUN_CMD nix-env -p /nix/var/nix/profiles/per-user/nix-on-droid/profile --delete-generations +2 2>/dev/null || true
    _free_kb=$(df -k "$HOME" 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2 {print $4}')
    if [ "''${FORCE_GC:-0}" = 1 ] || [ "''${_free_kb:-0}" -lt 4194304 ]; then
      echo "[trim-generations] GC running (free=$((_free_kb / 1048576))GiB < 4GiB or FORCE_GC=1)"
      $DRY_RUN_CMD nix-collect-garbage 2>/dev/null || true
    else
      echo "[trim-generations] GC skipped (free=$((_free_kb / 1048576))GiB ≥ 4GiB — FORCE_GC=1 to force)"
    fi
  '';

  # Goose AI CLI config (cloud-ai-cli alias)
  # NOTE: Goose can't follow Nix store symlinks, so we copy instead
  home.activation.gooseConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.config/goose"
    rm -f "$HOME/.config/goose/config.yaml"
    cp ${./dotfiles/goose/config.yaml} "$HOME/.config/goose/config.yaml"
    chmod 644 "$HOME/.config/goose/config.yaml"
  '';

  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.cargo/bin"
    "$HOME/.npm-global/bin"
    "$HOME/go/bin"
    "$HOME/.nix-profile/bin"
  ];

  nixpkgs.config.allowUnfree = true;
  news.display = "silent";
}
