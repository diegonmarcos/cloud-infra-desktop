{ config, lib, pkgs, ... }:

# my-konsole (KDE role) — the Rust (Tauri v2) Konsole-alternative app from
# da__my-konsole. Desktop integration is SELF-CONTAINED in the app: HM activation
# just runs `da__my-konsole/build.sh install`, which (data-driven from build.json)
# writes the ~/.local/bin/my-konsole launcher, the .desktop entry, and installs
# the personalized icon into the hicolor theme — so there is ONE source of the
# desktop entry/icon (build.json), never double-managed here.
#
# NOT here any more: the com.diegonmarcos.watchdog panel widget. build.sh used
# to cp it out of the working tree, so the deployed widget depended on what was
# checked out instead of on the generation. It is now vendored in the flake and
# installed from a store path — see home.activation.installWatchdogPlasmoid in
# modules/desktop/plasma.nix. Everything build.sh still installs below is a
# product of the app itself (binary, launcher, .desktop, icon, tray unit), so
# build.json stays the single source for those.
#
# The KDE *default terminal* is set in modules/desktop/plasma.nix. The bare-TTY/
# rescue role uses a real terminal emulator instead (a webview app can't run on
# a raw console) — see configuration_my-konsole-tty.nix + the rescue ISO.

let
  repoDir = "${config.home.homeDirectory}/git/cloud-u-linux/da__my-konsole";
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
