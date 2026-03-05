# Guardrails: PATH wrapper scripts in ~/.local/bin/
# Prints a declarative environment alert, then runs the real command.
# Works in both interactive and non-interactive shells (unlike shell functions).
{ config, lib, ... }:

let
  commands = [ "npm" "npx" "apt" "apt-get" "pip" "pip3" "pipx" "brew" "pacman" "yay" "paru" "dnf" "yum" "cargo" "go" "nix-env" "docker" "docker-compose" ];

  mkWrapper = cmd: {
    name = ".local/bin/${cmd}";
    value = {
      executable = true;
      text = ''
        #!/usr/bin/env bash
        echo -e "\033[1;31m  ╔══════════════════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;31m  ║  1) DECLARATIVE ONLY                                         ║\033[0m"
        echo -e "\033[1;31m  ║     THIS IS A FULL DECLARATIVE ENVIRONMENT, NIX-FLAKES WAY  ║\033[0m"
        echo -e "\033[1;31m  ╠══════════════════════════════════════════════════════════════╣\033[0m"
        echo -e "\033[1;33m  ║  2) BUILD.SH ALWAYS                                          ║\033[0m"
        echo -e "\033[1;33m  ║     JS deps  → build.sh deps | Build → build.sh build        ║\033[0m"
        echo -e "\033[1;33m  ║     Temp pkg → nix-shell -p <package>                        ║\033[0m"
        echo -e "\033[1;33m  ╠══════════════════════════════════════════════════════════════╣\033[0m"
        echo -e "\033[1;35m  ║  3) NO HARDCODE EASY FIX                                     ║\033[0m"
        echo -e "\033[1;35m  ║     Always report a bug in the build.sh engine               ║\033[0m"
        echo -e "\033[1;35m  ╚══════════════════════════════════════════════════════════════╝\033[0m"
        echo ""
        PATH="''${PATH//$HOME\/.local\/bin:/}" exec ${cmd} "$@"
      '';
    };
  };
in
{
  # Ensure ~/.local/bin is first on PATH so wrappers intercept commands
  home.sessionPath = [ "$HOME/.local/bin" ];

  home.file = builtins.listToAttrs (map mkWrapper commands);
}
