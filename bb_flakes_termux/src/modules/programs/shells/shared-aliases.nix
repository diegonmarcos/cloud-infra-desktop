# Interactive shells. Aliases are DERIVED from modules/data/fish-commands.json
# (entries flagged shared:true) and handed in as `sharedAliases` — hand-keeping a
# second copy here is what produced the `up` shadow that hid a managed fish
# function for months.
{ config, lib, pkgs, sharedAliases, ... }:

{
  programs.bash = {
    enable = true;
    shellAliases = sharedAliases;
    profileExtra = ''
      # ~/.local/bin AHEAD of nix-profile: the Authelia curl/wget
      # wrappers live there (curl-wget-wrapper.nix).
      export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH"
      # /etc self-heal — body lives in scripts/etc-self-heal.sh
      etc-self-heal 2>/dev/null || true
    '';
  };

  programs.zsh = {
    enable = true;
    shellAliases = sharedAliases;
  };

  programs.fish = {
    enable = true;
    # shellAliases intentionally absent — modules/programs/shells/
    # fish.nix generates the full fish set from fish-commands.json.
    # NO inline init here (2026-08-08 decree: flakes orchestrate,
    # scripts live in files): everything moved to
    # modules/programs/shells/fish/interactiveShellInit.fish.
    # The fzf_file/history/cd binds that lived here were DELETED,
    # not moved — they clobbered atuin's Ctrl+R and fzf's own
    # --fish bindings (2026-08-08 audit).
  };
}
