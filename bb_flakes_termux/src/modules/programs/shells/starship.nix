# Starship cross-shell prompt configuration
{ config, pkgs, lib, ... }:

{
  programs.starship = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
    enableFishIntegration = true;

    settings = {
      # Android/Termux git is slow on large repos (the home dir is a git repo
      # with many untracked files) — the 500ms default makes starship abort
      # `git status` and emit a timeout warning. 2000ms still fired on the
      # unix repo right after a switch (cold page cache); 5000ms covers the
      # measured worst case without ever blocking the prompt render itself.
      command_timeout = 5000;

      format = lib.concatStrings [
        "$time"
        "[ ❯](bold cyan) "
        "$directory"
        "$git_branch"
        "$git_status"
        "$container"
        "$cmd_duration"
        "$line_break"
        "$character"
      ];

      right_format = "$username$hostname";

      username = {
        show_always = false;
        style_user = "bold green";
        style_root = "bold red";
        format = "[$user]($style) ";
      };

      hostname = {
        ssh_only = true;
        format = "[@$hostname](bold yellow) ";
      };

      directory = {
        truncation_length = 4;
        truncate_to_repo = true;
        style = "bold blue";
        format = "[$path]($style)[$read_only]($read_only_style) ";
        read_only = " ";
        read_only_style = "red";
      };

      git_branch = {
        symbol = " ";
        style = "bold purple";
        format = "on [$symbol$branch]($style) ";
      };

      git_status = {
        conflicted = "";
        ahead = "^$count";
        behind = "v$count";
        diverged = "^$ahead_count v$behind_count";
        untracked = "?$count";
        stashed = "";
        modified = "!$count";
        staged = "+$count";
        renamed = ">>$count";
        deleted = "x$count";
        style = "bold yellow";
        format = "([$all_status$ahead_behind]($style) )";
      };

      container = {
        symbol = " ";
        style = "bold cyan";
        format = "[$symbol$name]($style) ";
      };

      cmd_duration = {
        min_time = 2000;
        format = "took [$duration](bold yellow) ";
      };

      time = {
        disabled = false;
        format = "[$time](bold cyan)";
        time_format = "%H:%M:%S";
      };

      character = {
        success_symbol = "[>](bold green)";
        error_symbol = "[>](bold red)";
        vimcmd_symbol = "[<](bold green)";
      };

      nodejs = {
        format = "[$symbol($version )]($style)";
        version_format = "\${raw}";
        symbol = " ";
        detect_files = [ "package.json" ".node-version" ];
      };

      python = {
        format = "[$symbol$pyenv_prefix($version )(\\($virtualenv\\) )]($style)";
        version_format = "\${raw}";
        symbol = " ";
        detect_files = [ ".python-version" "Pipfile" "pyproject.toml" "requirements.txt" ];
      };

      rust = {
        format = "[$symbol($version )]($style)";
        version_format = "\${raw}";
        symbol = " ";
        detect_files = [ "Cargo.toml" ];
      };

      golang = {
        format = "[$symbol($version )]($style)";
        version_format = "\${raw}";
        symbol = " ";
        detect_files = [ "go.mod" "go.sum" ];
      };

      nix_shell = {
        format = "[$symbol$state]($style) ";
        symbol = " ";
      };
    };
  };
}
