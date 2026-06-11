# aa_bootloader — UEFI Bootloader Engine

> Owner of the entire boot stack on this host. NixOS yields all bootloader
> management to this engine via `aa_nixos-surface_host/src/modules/nixos_yield.nix`.
> Single source of truth: `src/boot.json`. Apply via `./build.sh deploy`.

## What it does

| Concern | Mechanism |
|---|---|
| UEFI menu (interactive) | rEFInd 0.14.2 — manual stanzas rendered from `src/boot.json` |
| UEFI NVRAM entries | `efibootmgr` invocations from `dist/nvram/apply.sh` |
| GRUB chainload (fallback) | `dist/boot/grub/grub.cfg` rendered from same JSON |
| NixOS adapter | `src/adapters/nixos/{boot.json, hardware_bootloader_boot.nix, swap_hibernate.nix, nixos_yield.nix}` deployed into the host flake |
| Kernel + initrd staging | `dist/boot/kernels/` (rEFInd reads kernels directly via ext4 driver) |
| LUKS unlock | USB keyfile on Ventoy (UUID `223C-F3F8`) → password fallback |

## Layout

```
aa_bootloader/
├── README.md                          ← this file
├── SNAPSHOT-2026-05-01.md             ← frozen pre-redesign capture (do not update)
├── build.sh                           ← engine entrypoint
├── src/
│   ├── boot.json                      ← ★ single source of truth
│   ├── boot.schema.json               ← JSON schema
│   ├── adapters/
│   │   └── nixos/                     ← .nix modules deployed into host flake
│   ├── gen/                           ← render-* + deploy-* scripts
│   └── vendored/refind-0.14.2/        ← rEFInd binaries
├── dist/                              ← generated artefacts (deploy reads from here)
│   ├── adapters/nixos/                ← copies pushed into the host flake
│   ├── boot/efi/EFI/{NixOS-boot-efi,refind}/
│   ├── boot/grub/grub.cfg
│   ├── boot/kernels/
│   ├── nvram/apply.sh
│   ├── previews/
│   └── MANIFEST.txt
├── snapshots/                         ← live system captures (efibootmgr, GPT, LUKS, ESP, grub.cfg)
├── source-copies/                     ← read-only snapshot of nix sources at 2026-05-01
└── logs/                              ← build logs
```

## Commands

```bash
./build.sh generate                # src/ → dist/  (no live changes)
./build.sh validate                # boot.json schema + lint + rendered stanza-icon guard
./build.sh plan                    # show would-change diff
./build.sh deploy-nixos            # copy dist/adapters/nixos/* into host flake
./build.sh deploy-refind           # write rEFInd to /boot/efi/EFI/refind/ (run as root)
./build.sh deploy-grub             # write GRUB chainload
./build.sh deploy-nvram            # apply efibootmgr NVRAM entries
./build.sh deploy-all              # everything above
./build.sh status                  # dist/ freshness + last deploy times
./build.sh snapshot                # capture live state into snapshots/
```

`YES=1` for non-interactive deploys.

## Tester

`aa_nixos-surface_host/src/modules/test-bootloader-yield.sh` — 12 invariants
that prove NixOS has yielded bootloader, the deployed state matches the JSON
SoT, and there are no stale GRUB/Kubuntu/Arch references in the rest of the
repo. Run after any deploy.

## Current live state (auto-updated by `./build.sh status`)

Run `./build.sh status` to see the current boot order, dist/ freshness, and
deploy timestamps. For the GPT layout / NVRAM entries / refind.conf, look at
the freshly captured files under `snapshots/` (re-capture with
`./build.sh snapshot`).

## See also

- `~/git/unix/aa_nixos-surface_host/src/modules/nixos_yield.nix` — the NixOS-side disable
- `~/git/unix/aa_nixos-surface_host/src/modules/test-bootloader-yield.sh` — the verifier
- `SNAPSHOT-2026-05-01.md` — historical pre-redesign capture (frozen)
