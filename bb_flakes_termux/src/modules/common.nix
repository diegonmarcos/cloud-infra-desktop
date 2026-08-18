# Common configuration for Termux / nix-on-droid
{ config, pkgs, lib, ... }:

{
  imports = [
    ./programs/shells/bash.nix
    ./programs/shells/shared-aliases.nix
    ./programs/shells/fish.nix
    ./programs/shells/starship.nix
    ./programs/editors/vim.nix
    ./programs/git.nix
    ./programs/tmux.nix
  ];

  programs.home-manager.enable = true;

  # Authelia OIDC — paths to vault credentials + tokens
  home.sessionVariables = {
    AUTHELIA_OIDC_CREDENTIALS_DIR = "$HOME/git/cloud-vault/A0_keys/providers/authelia/signed-bearer_jwt/credentials";
    AUTHELIA_OIDC_TOKENS_DIR = "$HOME/git/cloud-vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens";
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
  # HM always wins — body in scripts/remove-imperative-packages.sh
  home.activation.removeImperativePackages = lib.hm.dag.entryBefore ["installPackages"] ''
    NIX_DIR="${pkgs.nix}/bin" ${pkgs.bash}/bin/bash ${./scripts/remove-imperative-packages.sh} || true
  '';

  # Generation trim on every switch, but full GC only under DISK PRESSURE.
  # nix-collect-garbage on every switch was the hidden performance killer:
  # deleting thousands of just-orphaned store paths evicts the kernel page
  # cache, so every warm binary (claude, node, tsx) cold-starts from flash
  # through proot afterwards — measured 11s directory lookups and a 4-minute
  # claude first-start right after a 5156-path GC (2026-08-08). Keeping the
  # 2 newest generations also preserves instant rollback.
  # Generation trim + pressure-gated GC — body in scripts/trim-generations.sh
  home.activation.trimGenerations = lib.hm.dag.entryAfter [ "installPackages" ] ''
    NIX_DIR="${pkgs.nix}/bin" AWK_BIN="${pkgs.gawk}/bin/awk" ${pkgs.bash}/bin/bash ${./scripts/trim-generations.sh} || true
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
