# Install Log — Debian Rescue OS

Append-only record of bootstrap runs and post-boot installs. Most recent at the bottom.

---

- 2026-05-03 22:10: Debian trixie bootstrapped to /dev/nvme0n1p6 (root UUID=42ccd674-d035-497d-b0eb-bffa28c5144c). chroot-setup.sh failed first run on `systemd-networkd` (not a separate apt package in trixie); fixed and resumed. ESP overflow on initrd copy → switched bootloader strategy: rEFInd reads p6 ext4 directly via volume label, loader=/vmlinuz, initrd=/initrd.img (auto-tracking symlinks). Menuentry "Debian Rescue OS" appended to /mnt/efi/EFI/refind/refind.conf.
