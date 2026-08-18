# 0_spec/ — pre-rEFInd era (ARCHIVED 2026-05-05)

> ⚠️ These documents describe the architecture of `aa_nixos-surface_host`
> as it was **before** the bootloader yield to `aa_bootloader/` and the
> partition relabels of 2026-05-04 → 2026-05-05.
>
> They reference:
> - GRUB as the primary bootloader (now rEFInd, owned by `aa_bootloader/`)
> - Kubuntu on p5 (now Shared-Lib for Docker storage)
> - Arch on p6 (now rescue-os-debian)
> - The repo living at `/mnt/kubuntu/home/diego/mnt_git/cloud-unix/a_nixos_host/`
>   (now `/home/diego/git/cloud-unix/aa_nixos-surface_host/`)
>
> **For the current architecture, see**:
>
> - `~/git/cloud-unix/README.md` — top-level multi-OS layout
> - `~/git/cloud-unix/aa_nixos-surface_host/README.md` — host quick start
> - `~/git/cloud-unix/aa_bootloader/README.md` — bootloader engine
> - `~/git/cloud-unix/aa_bootloader/src/boot.json` — single source of truth for boot
> - `~/git/cloud-unix/aa_nixos-surface_host/0_spec/runbook.md` — kept (still current)
> - `~/git/cloud-unix/aa_nixos-surface_host/0_spec/diagnose-nixos.sh` — kept (still current)

## Files in this archive

| File | What it was |
|---|---|
| `architecture.md` | System-level architecture diagram + rationale (old GRUB-on-Kubuntu era) |
| `USER-MANUAL.md` | Daily-usage cheat sheet pointing at `/mnt/kubuntu/...` paths |
| `ISSUES-STATUS.md` | Issue tracker from the 2026-01 install push |
| `task_1.md` | Single-task tracking file |
| `CHANGES-2026-01-08.md` | Changelog entry for the initial Kubuntu→NixOS migration |

These remain only as a record of the system's history. Do not run any
script here — paths and UUIDs are obsolete.
