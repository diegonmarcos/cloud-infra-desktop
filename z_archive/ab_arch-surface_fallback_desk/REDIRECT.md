# ARCHIVED — replaced by `ab_rescue-os-debian` on p6

Archived **2026-05-05**.

## Why

Partition p6 (UUID `42ccd674-d035-497d-b0eb-bffa28c5144c`) was reformatted from
Arch Linux to Debian trixie minimal CLI as a rescue OS. The Arch fallback
desktop is no longer the on-disk recovery target.

## Where to look now

| Concern | New location |
|---|---|
| Rescue OS install scripts | `ab_fallback_os/ab_kali_security/os_debootstrap/` (mirrored Debian-style approach) |
| rEFInd menu entry | `aa_bootloader/src/boot.json` → `grub.menu.arch` (key kept, contents now point at `42ccd674-...`, label "Rescue OS — Debian") |
| Live rescue partition (p6) | mounted manually via `sudo mount /dev/nvme0n1p6 /mnt/rescue-os-debian` |
| Pre-rEFInd snapshot of the old GRUB stack | `aa_bootloader/snapshots/` |

## What's preserved here

- `bootstrap/` — original Arch install scripts (historical)
- `install.{json,md,sh,tar}` — the Arch installer artefacts
- `SETUP.md`, `TOOLS.md`, `install_log.md` — the setup notes used during the
  Arch-on-p6 era (2026-04-29 → 2026-05-03)

These remain only as a reference for how the dual-boot was first set up.
Do not run any script from this directory — they target the old UUID
(`1648a2fb-...`) which is no longer present on disk.
