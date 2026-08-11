# desktop/store-search.nix — KDE/KRunner search over the /nix/store closure,
# with ZERO indexing ever running on this machine.
#
# BACKGROUND (2026-08-11): baloo was killing this box. It indexed all of $HOME,
# sustained ~50% CPU in baloo_file_extractor, and drove user.slice to 49.4%
# memory pressure until systemd-oomd killed plasmashell. It had been "disabled"
# for a month but desktop/plasma.nix rendered Indexing-Enabled=true into the
# store on every switch, silently overriding the activation-time balooctl call
# (which could never persist anyway — HM links baloofilerc read-only).
#
# WHY CI CAN BUILD THIS INDEX BUT COULD NEVER BUILD BALOO'S:
#   baloo   → document key = (st_dev, st_ino). Inodes differ per filesystem, so
#             a CI-built baloo DB is meaningless here. Not fixable.
#   plocate → document key = PATH. /nix/store paths are content-addressed and
#             byte-identical on every machine, so CI's DB transplants exactly.
# That single property is what makes the whole build-in-CI design possible.
#
# PIPELINE:
#   CI    aa_desk-usr.../build.sh ci_build()      → dist-ci-index/store.db
#   GHA   ship_nix-flakes_desktop_nixos.yaml      → artifact nixos-surface-search-index
#   Local steps/60-fetch-search-index.sh          → ~/.local/share/store-search/store.db
#   Here  D-Bus-activated KRunner runner queries that DB
#
# Shipped WHOLE, not diffed like the closure: ~1.5MB for a ~240k-file closure.
{ config, pkgs, lib, ... }:

let
  runnerEnv = pkgs.python3.withPackages (ps: [ ps.dbus-python ps.pygobject3 ]);

  storeSearchRunner = pkgs.stdenv.mkDerivation {
    name = "store-search-runner";
    src = ./store-search-runner.py;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      mkdir -p $out/bin
      cp $src $out/bin/store-search-runner
      chmod +x $out/bin/store-search-runner
      patchShebangs $out/bin/store-search-runner
      # plocate provides the query binary; xdg-open handles Run().
      wrapProgram $out/bin/store-search-runner \
        --prefix PATH : ${lib.makeBinPath [ pkgs.plocate pkgs.xdg-utils ]}
    '';
    buildInputs = [ runnerEnv ];
  };
in
{
  # Query binary must also be on PATH for manual `plocate -d ...` debugging.
  home.packages = [ pkgs.plocate ];

  # D-Bus activation rather than a systemd user service: nothing runs until
  # someone actually types in KRunner. A permanently-resident indexer daemon is
  # precisely what this module exists to eliminate.
  xdg.dataFile."dbus-1/services/org.kde.runners.storesearch.service".text = ''
    [D-BUS Service]
    Name=org.kde.runners.storesearch
    Exec=${storeSearchRunner}/bin/store-search-runner
  '';

  # Plasma 6 D-Bus runner manifest. Key names verified against the shipped
  # plasma-runner-baloosearch.desktop — Plasma 6 uses X-Plasma-API=DBus, NOT
  # the KDE4-era X-KDE-DBUS-Runner-* keys, and gets no error if they're wrong:
  # the runner just silently never loads.
  xdg.dataFile."krunner/dbusplugins/store-search.desktop".text = ''
    [Desktop Entry]
    Type=Service
    Name=Nix Store Search
    Comment=Find files in the NixOS system closure
    Icon=nix-snowflake
    X-KDE-ServiceTypes=Plasma/Runner
    X-KDE-PluginInfo-Name=store-search
    X-KDE-PluginInfo-Author=diego
    X-KDE-PluginInfo-License=MIT
    X-KDE-PluginInfo-EnabledByDefault=true
    X-Plasma-API=DBus
    X-Plasma-DBusRunner-Service=org.kde.runners.storesearch
    X-Plasma-DBusRunner-Path=/runner
    X-Plasma-Runner-Min-Letter-Count=3
  '';
}
