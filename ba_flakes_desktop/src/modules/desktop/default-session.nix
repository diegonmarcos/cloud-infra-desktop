# default-session.nix — DECLARATIVE default 4-desktop login layout.
#
# Supersedes the Plasma-native session-restore path (./session-restore.nix) with
# an EXPLICIT, data-driven launcher (the approach session-restore.nix's header
# called "abandoned" — now viable because per-desktop pinning + L/R tiling are
# done via a KWin script keyed on PID, and Konsole tab titles are made sticky via
# setTabTitleFormat over DBus).
#
# PIECES (all driven by ./default-session.json — the single source of truth):
#   1. default-session.json          → the layout DATA (edit this to change anything)
#   2. default-session-launcher.sh   → the ENGINE (launch + title + pin + tile)
#   3. autostart/.desktop            → fires the engine ONCE per real login
#
# "NEVER HOLDS THE LOGIN" (the user's hard requirement):
#   The launcher runs from a Plasma autostart entry (X-KDE-autostart-condition=
#   ksmserver) — i.e. AFTER the session is up, so it cannot block login. Every app
#   is spawned detached, every wait is `timeout`-bounded, every failure is logged
#   and skipped, and the script always exits 0. Thresholds live in the JSON
#   .fallback block. (See default-session-launcher.sh header.)
#
# It only fires at a genuine login — NOT on `build.sh switch` — because it is a
# Plasma autostart .desktop, not a systemd unit that home-manager would restart.
{ config, lib, pkgs, ... }:
let
  shareDir = ".local/share/default-session";
  launcher = "${config.home.homeDirectory}/${shareDir}/default-session-launcher.sh";
in
{
  # ── Deploy the engine + data (source-of-truth files, read at runtime) ──────
  home.file."${shareDir}/default-session-launcher.sh" = {
    source = ./default-session-launcher.sh;
    executable = true;
  };
  home.file."${shareDir}/default-session.json".source = ./default-session.json;

  # jq is the launcher's only hard dependency that isn't part of KDE/the session.
  home.packages = [ pkgs.jq ];

  # ── Login behaviour: start empty, let our launcher populate the 4 desktops ──
  # (Ownership of loginMode moved here from ./session-restore.nix to avoid a
  #  double-definition; emptySession prevents Plasma ALSO restoring a previous
  #  session, which would double-launch on top of our layout.)
  programs.plasma.configFile.ksmserverrc.General.loginMode = "emptySession";

  # ── Fire the engine once per real login ────────────────────────────────────
  xdg.configFile."autostart/default-session.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Default Session Layout
    Comment=Restore Diego's default 4-desktop window arrangement (data: default-session.json)
    Exec=${launcher}
    X-KDE-autostart-condition=ksmserver
    X-KDE-autostart-phase=2
    OnlyShowIn=KDE;
    NoDisplay=true
  '';
}
