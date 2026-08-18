# Debian Rescue OS — Installation Guide

> **Target**: Surface Pro 8, fallback partition `/dev/nvme0n1p6` (5 GB)
> **Replaces**: Arch (`ab_arch-surface_fallback_desk`)
> **Bootloader**: rEFInd (no GRUB; no systemd-boot)
> **Hostname**: `rescue-os-debian`

---

## Quick Start (from a running Kali)

```bash
cd ~/git/cloud-unix/rescue-os-debian

# Sanity-check the JSON spec:
jq . install.json | head

# Run the bootstrapper (mkfs + debootstrap + chroot setup + rEFInd):
sudo ./bootstrap/install-debian.sh

# Reboot, select "Debian Rescue OS" in rEFInd
# Login: diego / 1234567890

# After first boot, inside Debian:
cd ~/git/cloud-unix/rescue-os-debian
./install.sh scan          # confirm packages
./install.sh install       # fix anything missed
./install.sh browser       # Firefox for Claude OAuth
./install.sh claude        # use Claude Code
```

---

## What the Bootstrapper Does

`bootstrap/install-debian.sh` (run from another distro, e.g. Kali):

1. Pre-flight checks: target partition exists, ESP mounted, scripts present, target unmounted.
2. Confirms with the user before any destructive op.
3. Installs `debootstrap` on the host if missing.
4. **`mkfs.ext4 -F -L debian /dev/nvme0n1p6`** — wipes p6.
5. Mounts p6 at `/mnt/p6`.
6. **`debootstrap --variant=minbase trixie /mnt/p6 …`** — base system (~350 MB).
7. Copies in `apt-sources.list`, host's `/etc/resolv.conf`, and `chroot-setup.sh`.
8. Bind-mounts `/proc`, `/sys`, `/dev` into the chroot.
9. Runs `chroot-setup.sh` inside the chroot:
   - TZ → `Europe/Madrid`, locale → `en_US.UTF-8`, hostname → `rescue-os-debian`
   - Installs kernel + firmware + base CLI + network + browser stack + Node + Claude Code
   - Creates user `diego` (UID 1000, fish shell, NOPASSWD sudo)
   - Sets root + diego password to `1234567890`
   - Creates mount points `/mnt/{efi,boot,pool,shared-lib,kali}`
   - Enables `NetworkManager`, `ssh`, `systemd-resolved`; masks `systemd-networkd` (kept installed but inactive)
   - Writes `/etc/quickref` and configures bash + fish to display it on every login
10. Generates `/etc/fstab` (root + every other partition as `noauto`) and `/etc/crypttab` (LUKS pool).
11. Copies `TOOLS.md` → `/home/diego/README.md` (the master tools doc).
12. Copies the entire install dir → `/home/diego/git/cloud-unix/rescue-os-debian/` so the user can re-run `./install.sh` without unlocking the pool first.
13. Copies kernel + initrd to `/mnt/efi/EFI/debian/{vmlinuz,initrd.img}`.
14. Appends a `menuentry "Debian Rescue OS"` to `/mnt/efi/EFI/refind/refind.conf` (idempotent — skipped if already present).
15. Cleanup mounts.

---

## What `./install.sh` Does (post-boot)

After first boot, this is the day-to-day tool. Idempotent — safe to re-run.

| Command | What |
|---|---|
| `scan` | Generates `install_check.md` listing installed/missing packages and services. |
| `install` | `apt install` everything in `install.json` that's missing. Adds NodeSource if Node missing. Installs npm globals. Enables services. |
| `browser` | `startx /usr/bin/firefox-esr` — one-shot Firefox, no WM. Use this for Claude OAuth fingerprint checks. |
| `session` | Full i3 X session via `startx` (creates `~/.xinitrc` if missing). |
| `kiosk` | `cage -- firefox-esr` — Wayland kiosk single-app. |
| `claude` | `exec claude`. |
| `mount-pool` | `cryptsetup open` + `mount /mnt/pool`. |
| `mount-all` | Mount every `noauto` fstab entry except encrypted. |
| `help` | Usage. |

---

## Phases

### Phase 1 — Bootstrap (from Kali)
Run `sudo ./bootstrap/install-debian.sh`. Approve the destructive prompt. Wait 5–10 minutes.

### Phase 2 — First Boot
Reboot. rEFInd shows "Debian Rescue OS". Pick it. Log in as `diego` / `1234567890`.

### Phase 3 — Verification
```bash
cd ~/git/cloud-unix/rescue-os-debian
./install.sh scan
```
Review `install_check.md`. If anything is missing, run `./install.sh install`.

### Phase 4 — Claude Code Auth
```bash
./install.sh browser     # Firefox opens, log in at claude.ai
# After login completes (and tokens are saved), close Firefox.
claude                   # should pick up the saved session
```

Or set an API key directly:
```fish
set -Ux ANTHROPIC_API_KEY sk-ant-...
claude
```

---

## Disk Layout (post-install)

| # | Size | FS | Label | Mount | Purpose |
|---|---|---|---|---|---|
| 1 | 100 MB | vfat | EFI | `/mnt/efi` (noauto) | UEFI ESP — rEFInd + per-distro kernels |
| 2 | 16 MB | (raw) | MSR | — | Microsoft Reserved |
| 3 | 2 GB | ext4 | boot | `/mnt/boot` (noauto) | Shared `/boot` (legacy NixOS GRUB area; now optional storage for kernels) |
| 4 | 79.8 GB | LUKS/btrfs | pool | `/mnt/pool` (noauto) | NixOS encrypted pool (`@nixos`, `@home-diego`, `@home-guest`, `@shared`) |
| 5 | 118.4 GB | ext4 | Shared-Lib | `/mnt/shared-lib` (noauto) | Docker data-root + cross-OS shared libs |
| 6 | 5 GB | ext4 | **debian** | `/` | **This Debian rescue OS** |
| 7 | 25 GB | ext4 | kali-root | `/mnt/kali` (noauto) | Kali root |

---

## Why "noauto" everywhere?

A rescue OS must boot fast and not depend on other partitions. If p3 or p5 is corrupted, this Debian still boots. Mount on demand via `./install.sh mount-all` or individual `sudo mount /mnt/X`.

The LUKS pool stays out of `/etc/crypttab`'s auto-unlock (entry has `noauto`) so we don't block boot on a passphrase prompt. Use `./install.sh mount-pool` when you need it.

---

## Recovering from a Broken Debian Rescue OS

If you somehow break this Debian itself, boot another distro from rEFInd, then:

```bash
sudo mount /dev/nvme0n1p6 /mnt/p6
sudo mount --rbind /dev /mnt/p6/dev
sudo mount --rbind /sys /mnt/p6/sys
sudo mount -t proc proc /mnt/p6/proc
sudo chroot /mnt/p6 /bin/bash
# Fix away. Exit, then reboot.
```

Or wipe + reinstall:

```bash
sudo ~/git/cloud-unix/rescue-os-debian/bootstrap/install-debian.sh
```

---

## See Also

- `TOOLS.md` — full tools reference (also written to `~/README.md` on the rescue OS).
- `SETUP.md` — pre-bootstrap host setup (rare; only if Kali doesn't have `debootstrap` available).
- `install.json` — declarative spec.
- `bootloader_refind.md` (memory) — why no GRUB.
