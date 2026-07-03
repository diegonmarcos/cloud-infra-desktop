# Standalone qutebrowser config bundle — NOT the desktop home-manager
# closure. Evaluates ONLY `programs.da_browser-qute` via a minimal
# `home-manager.lib.homeManagerConfiguration` (reusing home-manager's real
# `programs.qutebrowser` renderer — the same code path the desktop flake
# uses — so the JSON→config.py logic lives in exactly one place: home-module.nix).
#
# Output: config.py + quickmarks + bookmarks/urls + dashboard.html + a
# `--basedir`-isolated launcher script, packaged as a tarball. This is what
# `build.sh release` builds and ships to GitHub Releases — a few hundred KB,
# independent of the ~6GB 37-module desktop HM closure. Installing it never
# touches ~/.config/qutebrowser (the HM-managed one); it runs isolated via
# `qutebrowser --basedir ~/.local/share/qutebrowser-standalone`.

{ nixpkgs, home-manager, system ? "x86_64-linux" }:
let
  pkgs = import nixpkgs { inherit system; };

  hm = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ./home-module.nix
      {
        programs.da_browser-qute.enable = true;
        home.username = "diego";
        home.homeDirectory = "/home/diego";
        home.stateVersion = "24.11";
      }
    ];
  };

  cfg = hm.config;
  configPy    = cfg.xdg.configFile."qutebrowser/config.py".source;
  quickmarks  = cfg.xdg.configFile."qutebrowser/quickmarks".source;
  bookmarks   = cfg.xdg.configFile."qutebrowser/bookmarks/urls".source;
  dashboard   = cfg.xdg.configFile."qutebrowser/dashboard.html".source;

  launcher = pkgs.writeShellScriptBin "qutebrowser-standalone" ''
    set -euo pipefail
    basedir="''${QUTE_STANDALONE_BASEDIR:-$HOME/.local/share/qutebrowser-standalone}"
    mkdir -p "$basedir/config/bookmarks"
    cp -f "${configPy}"   "$basedir/config/config.py"
    cp -f "${quickmarks}" "$basedir/config/quickmarks"
    cp -f "${bookmarks}"  "$basedir/config/bookmarks/urls"
    cp -f "${dashboard}"  "$basedir/config/dashboard.html"
    exec ${pkgs.qutebrowser}/bin/qutebrowser --basedir "$basedir" "$@"
  '';
in
pkgs.runCommand "qutebrowser-standalone-bundle" {} ''
  mkdir -p $out
  cp ${configPy}   $out/config.py
  cp ${quickmarks} $out/quickmarks
  mkdir -p $out/bookmarks
  cp ${bookmarks}  $out/bookmarks/urls
  cp ${dashboard}  $out/dashboard.html
  cp ${launcher}/bin/qutebrowser-standalone $out/qutebrowser-standalone
  chmod +x $out/qutebrowser-standalone
''
