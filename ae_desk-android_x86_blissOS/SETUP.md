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
  where (`install.src_dir` on p5), which payload files, the `data.img` size, and the `apps`
  block (app-seed set + adb target).
- **`apps.lock.json`** — the app-seed manifest referenced by `blissos.json` `apps.lock`. Each
  entry is pinned by `url` + SRI `sha256`: alternative stores (F-Droid, Aurora, Obtainium), the
  FOSS app suite, and all four `aa_cloud-*` APKs (x86_64 variants for SuperApp/Nav, hubs for
  Comms/IDE). Seeded from the `da_waydroid-apps` set.
- **Boot entry** lives in `aa_bootloader/src/boot.json` (single SoT for the bootloader):
  - `grub.menu.blissos` — `root_param:/dev/ram0`, kernel `/blissos/kernel`, android cmdline
    (`SRC=/blissos DATA=`), booted from p5 (UUID `7e3626ac…`).
  - `grub.linux_order[]` — includes `blissos`.
  - `refind.manual_stanzas.order[]` — `efi_chainload from:blissos`, icon `os_android`.

## Install (one-time, interactive — needs root + p5 mounted)
```
cd ~/git/cloud-infra-desktop/ae_desk-android_x86_blissOS/install
# 1. Choose a BlissOS x86_64 release and put its .iso URL in ../blissos.json (release.url)
#    (BlissRoms/x86 releases; vanilla by default). Then pin it:
./build.sh lock                 # prefetch + record release.sha256 (reproducible)
# 2. Lay the payload into /mnt/shared-lib/blissos + create data.img:
./build.sh install
# 3. Render + install the boot entry (rEFInd + GRUB):
( cd ../../aa_bootloader && ./build.sh deploy )
./build.sh status               # verify /blissos contents
# 4. Pre-fetch the seed apps (hash-verified, reproducible) — can run any time:
./build.sh fetch-apks           # nix-prefetch every apps.lock entry into dist/apks/
```
Reboot → rEFInd shows **"BlissOS - Android"** → it chainloads GRUB → boots `/blissos/kernel`.

## Seed apps (one-time, after first boot)
BlissOS boots as a full OS, so apps are installed over **adb** (Android's package manager must
register each one — dropping APKs into `data.img` does not install them). In BlissOS: Settings →
System → Developer options → enable **ADB / wireless debugging**, note its `ip:port` (default
here `127.0.0.1:5555` if you boot BlissOS in a VM with a forwarded port; use the LAN ip:port for
bare-metal). Then from the desktop:
```
cd ~/git/cloud-infra-desktop/ae_desk-android_x86_blissOS/install
./build.sh fetch-apks           # (if not already) hash-verified download into dist/apks/
./build.sh provision            # adb connect + adb install -r -g every APK (stores + FOSS + aa_cloud-*)
```
`provision` is idempotent (`-r` reinstalls, keeps data). Adjust `apps.adb_target` in
`blissos.json` to match your device's ADB address.

Remove: `./build.sh uninstall` then drop the three boot.json blissos references + `deploy`.

## Notes
- `install.iso_payload_subdir` may need setting if the release stores kernel/initrd under a
  subdir on the ISO (varies by BlissOS build) — `install` errors clearly if a file is missing.
- GPU: BlissOS ships Mesa; the SP8 Intel Xe works out of the box. If black-screen, add
  `nomodeset`/`GRALLOC=gbm` to `grub.menu.blissos.options` in boot.json + re-`deploy`.
- The boot entry is verified at render time (`aa_bootloader/build.sh build-grub|build-refind`
  emit it into `dist/` with no system writes); `deploy` is the only step that writes the ESP.
