{ config, lib, pkgs, ... }:

# my-konsole (KDE role) — install our Rust (Tauri v2) Konsole-alternative app
# from da_my-konsole and register it as a desktop terminal. On HM activation we
# run `da_my-konsole/build.sh install`, which writes a ~/.local/bin/my-konsole
# launcher (→ build.sh run: local build > fetched CI binary). Cheap, idempotent,
# never blocks activation. The KDE *default terminal* is set in modules/desktop/
# plasma.nix (TerminalApplication/TerminalService).
#
# (The bare-TTY/rescue role uses a real terminal emulator instead — a webview
# app can't run on a raw console — see configuration_my-konsole-tty.nix + the
# my-konsole rescue ISO.)

let
  repoDir = "${config.home.homeDirectory}/git/unix/da_my-konsole";
in
{
  home.packages = with pkgs; [ zstd curl jq ];

  xdg.desktopEntries."my-konsole" = {
    name = "my-konsole";
    genericName = "Terminal";
    comment = "Rust KDE Konsole alternative — tabbed terminal, profiles, command sections";
    exec = "${config.home.homeDirectory}/.local/bin/my-konsole";
    icon = "utilities-terminal";
    terminal = false;
    type = "Application";
    startupNotify = true;
    categories = [ "System" "TerminalEmulator" "Utility" ];
    settings.StartupWMClass = "com.diegonmarcos.my-konsole";
  };

  home.activation.myKonsoleInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -x "${repoDir}/build.sh" ]; then
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash "${repoDir}/build.sh" install || \
          echo "my-konsole: install skipped/failed (non-fatal)"
      else
        echo "my-konsole: ${repoDir}/build.sh absent — skipping install"
      fi
    '';
}
