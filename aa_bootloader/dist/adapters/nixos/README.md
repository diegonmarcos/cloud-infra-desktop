# dist/adapters/nixos/

GENERATED. Do not edit.

The .nix files here are copied verbatim from `aa_bootloader/src/adapters/nixos/`
by `gen/render-nixos-adapter.sh`. `boot.json` is copied from `aa_bootloader/src/`.

`targets/deploy-nixos.sh` copies this directory's contents into the NixOS
flake at `aa_nixos-surface_host/src/modules/`, then triggers nixos-rebuild.

To change the contents: edit `aa_bootloader/src/`, run
`aa_bootloader/build.sh generate`, then `build.sh deploy --target nixos`.
