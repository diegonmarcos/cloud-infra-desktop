# ae_desk-android_x86_blissOS

BlissOS x86_64 as a **boot-menu entry** on the Surface Pro 8, alongside NixOS / Kali /
Debian / Windows. Sibling of `ab_desk-security_x86_kali-linux_kali` and
`ac_rescue-os_x86_debian-linux_debian`.

## Why install-to-folder (not a partition)
The 256 GB NVMe is **fully partitioned** (p1 ESP · p2 boot · p4 LUKS pool · p5 Shared-Lib ·
p6 rescue · p7 kali) — **no free space** for a native BlissOS partition. So BlissOS is laid
into a **folder on the existing ext4 p5** (`/mnt/shared-lib/blissos/`), android-x86
"install without formatting" style, and booted **directly by rEFInd**: a native
`linux_partition` stanza (`volume` = p5, `loader /blissos/kernel`) — rEFInd's `ext4_x64.efi`
driver reads the real kernel file off p5 (no GRUB chainload; that's only needed for
Debian/Kali whose `/vmlinuz` is a symlink rEFInd can't follow). Reversible: delete the folder
+ the boot entry, no repartition.

## Data model
- **`blissos.json`** — the install SoT: which release (`release.url` + pinned `release.sha256`),
  where (`install.src_dir` on p5), which payload files, and the `data.img` size.
- **Boot entry** lives in `aa_bootloader/src/boot.json` (single SoT for the bootloader):
  - `grub.menu.blissos` — `root_param:/dev/ram0`, kernel `/blissos/kernel`, android cmdline
    (`SRC=/blissos DATA=`), booted from p5 (UUID `7e3626ac…`).
  - `grub.linux_order[]` — includes `blissos`.
  - `refind.manual_stanzas.order[]` — `efi_chainload from:blissos`, icon `os_android`.

## Install (one-time, interactive — needs root + p5 mounted)
```
cd ~/git/unix/ae_desk-android_x86_blissOS/install
# 1. Choose a BlissOS x86_64 release and put its .iso URL in ../blissos.json (release.url)
#    (BlissRoms/x86 releases; vanilla by default). Then pin it:
./build.sh lock                 # prefetch + record release.sha256 (reproducible)
# 2. Lay the payload into /mnt/shared-lib/blissos + create data.img:
./build.sh install
# 3. Render + install the boot entry (rEFInd + GRUB):
( cd ../../aa_bootloader && ./build.sh deploy )
./build.sh status               # verify /blissos contents
```
Reboot → rEFInd shows **"BlissOS - Android"** → it chainloads GRUB → boots `/blissos/kernel`.

Remove: `./build.sh uninstall` then drop the three boot.json blissos references + `deploy`.

## Notes
- `install.iso_payload_subdir` may need setting if the release stores kernel/initrd under a
  subdir on the ISO (varies by BlissOS build) — `install` errors clearly if a file is missing.
- GPU: BlissOS ships Mesa; the SP8 Intel Xe works out of the box. If black-screen, add
  `nomodeset`/`GRALLOC=gbm` to `grub.menu.blissos.options` in boot.json + re-`deploy`.
- The boot entry is verified at render time (`aa_bootloader/build.sh build-grub|build-refind`
  emit it into `dist/` with no system writes); `deploy` is the only step that writes the ESP.
