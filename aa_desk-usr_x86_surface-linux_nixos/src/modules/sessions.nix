# Sessions orchestrator — imports all session submodules
{ config, pkgs, lib, ... }:

{
  imports = [
    ./sessions_sddm.nix
  ];
}
