{
  description = "da_browser-qute — qutebrowser daily-driver with daemon integrations (FIDO2 + autofill)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    {
      # System-independent home-manager module. Consumer wires this in their
      # home flake; the module reads JSON in src/2_configs/ at evaluation
      # time so editing the JSON is the only thing the operator does after
      # initial install.
      homeManagerModules.default = import ./nix/home-module.nix;
    };
}
