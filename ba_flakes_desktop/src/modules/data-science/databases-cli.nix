# data-science/databases-cli.nix — database engines + interactive CLIs
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    sqlite
    postgresql
    mysql80
    redis
    # mongodb    # DISABLED: builds from source (~2-3 hours!)

    # Interactive CLIs
    pgcli
    mycli
    litecli
  ];
}
