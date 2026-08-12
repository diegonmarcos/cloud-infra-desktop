# Git configuration
{ config, pkgs, lib, ... }:

{
  programs.git = {
    enable = true;

    userName = "Diego Nepomuceno Marcos";
    userEmail = "me@diegonmarcos.com";

    extraConfig = {
      init.defaultBranch = "main";

      core = {
        editor = "vim";
        autocrlf = "input";
        whitespace = "fix,-indent-with-non-tab,trailing-space,cr-at-eol";
        pager = "less -FRX";
      };

      color = {
        ui = "auto";
        branch = "auto";
        diff = "auto";
        status = "auto";
      };

      merge = {
        tool = "vimdiff";
        conflictstyle = "diff3";
      };

      diff = {
        tool = "vimdiff";
        algorithm = "patience";
      };

      push = {
        default = "current";
        autoSetupRemote = true;
      };

      pull.rebase = true;
      fetch.prune = true;
      rebase.autoStash = true;
      submodule.recurse = true;
    };

    aliases = {
      s = "status -sb";
      st = "status";
      c = "commit";
      cm = "commit -m";
      ca = "commit --amend";
      can = "commit --amend --no-edit";
      b = "branch";
      ba = "branch -a";
      bd = "branch -d";
      bD = "branch -D";
      co = "checkout";
      cob = "checkout -b";
      l = "log --oneline -20";
      lg = "log --graph --oneline --decorate -20";
      ll = "log --pretty=format:'%C(yellow)%h%Creset %s %C(cyan)<%an>%Creset %C(green)(%cr)%Creset' -20";
      hist = "log --pretty=format:'%h %ad | %s%d [%an]' --graph --date=short";
      d = "diff";
      ds = "diff --staged";
      dc = "diff --cached";
      p = "push";
      pf = "push --force-with-lease";
      pl = "pull";
      plr = "pull --rebase";
      ss = "stash save";
      sl = "stash list";
      sp = "stash pop";
      sa = "stash apply";
      sd = "stash drop";
      unstage = "reset HEAD --";
      discard = "checkout --";
      undo = "reset --soft HEAD~1";
      aliases = "config --get-regexp alias";
      whoami = "!git config user.name && git config user.email";
      root = "rev-parse --show-toplevel";

      # gacp: git add all + commit + push (happy path)
      gacp = "!f() { git add -A && git commit -m \"$1\" && git push; }; f";

      # sync-remote: gacp failed? fetch + rebase (remote wins conflicts) + push
      sync-remote = "!f() { git pull --rebase -X theirs && git push; }; f";
      # sync: the 6-step engine (stash→fetch→rebase→push→pop→submodules).
      # Declared here so `git sync` works on fresh installs too — before, it
      # existed only via the imperative gitconfig include in this checkout.
      sync = "!./1_cicd/dist/scripts/cloud-git-sync.sh";
    };

    ignores = [
      # OS
      ".DS_Store"
      "*~"
      ".directory"
      "Thumbs.db"

      # Editors
      ".vscode/"
      ".idea/"
      "*.swp"
      "*.swo"
      "*~"

      # Build
      "node_modules/"
      "build/"
      "__pycache__/"
      "*.pyc"
      ".cache/"
      "target/"

      # Env/Secrets
      ".env"
      ".env.local"
      "*.pem"
      "*.key"

      # Logs
      "*.log"
      "*.sqlite"

      # Terraform
      "*.tfstate"
      "*.tfstate.backup"
      ".terraform/"

      # Nix
      "result"
      "result-*"
    ];
  };
}
