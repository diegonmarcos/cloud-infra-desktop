# containers-cloud/secrets.nix — secrets management CLIs
# Parallel copy in security-net/secrets.nix is intentional: hosts that import
# only the IaC bundle still need sops+age, and hosts importing only the
# security bundle still need them. Nix dedupes when both are imported.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    sops
    age
    # vault      # DISABLED: builds from source (~20min)
  ];
}
