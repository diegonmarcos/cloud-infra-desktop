{ config, lib, pkgs, ... }:

# my-konsole (KDE role) — the Rust (Tauri v2) Konsole-alternative app from
# da_my-konsole. Desktop integration is SELF-CONTAINED in the app: HM activation
# just runs `da_my-konsole/build.sh install`, which (data-driven from build.json)
# writes the ~/.local/bin/my-konsole launcher, the .desktop entry, and installs
# the personalized icon into the hicolor theme — so there is ONE source of the
# desktop entry/icon (build.json), never double-managed here.
#
# The KDE *default terminal* is set in modules/desktop/plasma.nix. The bare-TTY/
# rescue role uses a real terminal emulator instead (a webview app can't run on
# a raw console) — see configuration_my-konsole-tty.nix + the rescue ISO.

let
  repoDir = "${config.home.homeDirectory}/git/unix/da_my-konsole";
in
{
  home.packages = with pkgs; [ zstd curl jq ];

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
