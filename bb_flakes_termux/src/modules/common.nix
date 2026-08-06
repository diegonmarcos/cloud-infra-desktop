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

  # No generation accumulation on termux — keep only the current gen, GC the rest.
  # Runs on every switch (no systemd/cron on Android). --delete-generations old
  # never removes the current generation, so this is safe mid-activation.
  home.activation.trimGenerations = lib.hm.dag.entryAfter [ "installPackages" ] ''
    export PATH="${pkgs.nix}/bin:$PATH"
    $DRY_RUN_CMD nix-env -p /nix/var/nix/profiles/nix-on-droid --delete-generations old 2>/dev/null || true
    $DRY_RUN_CMD nix-env -p "$HOME/.local/state/nix/profiles/home-manager" --delete-generations old 2>/dev/null || true
    $DRY_RUN_CMD nix-env -p /nix/var/nix/profiles/per-user/nix-on-droid/profile --delete-generations old 2>/dev/null || true
    $DRY_RUN_CMD nix-collect-garbage 2>/dev/null || true
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
