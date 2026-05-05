# Debian Rescue OS — Host Setup (Pre-Bootstrap)

Almost always nothing to do here — Kali ships with `apt`, internet, and ESP auto-mounts. But for rare cold-start scenarios:

## Requirements on the host (Kali / NixOS / Ventoy live USB / any Debian-family)

1. **Internet access** — `deb.debian.org` reachable.
2. **`debootstrap`** — the bootstrapper auto-installs it on Debian-family hosts. On NixOS: `nix-shell -p debootstrap`.
3. **ESP mounted** at `/mnt/efi` (or override via `ESP=/some/path`).
4. **rEFInd installed** at `/mnt/efi/EFI/refind/` — checked by the script; missing config is non-fatal but you'll need to add the menuentry manually.
5. **Sudo access**.

## Override defaults

The bootstrapper accepts environment variables:

```bash
sudo TARGET=/dev/nvme0n1p6 \
     SUITE=trixie \
     MIRROR=http://deb.debian.org/debian \
     HOSTNAME_NEW=rescue-os-debian \
     ESP=/mnt/efi \
     ./bootstrap/install-debian.sh
```

## If running from NixOS

```bash
nix-shell -p debootstrap --run 'sudo ./bootstrap/install-debian.sh'
```

## If running from inside the rescue chroot of another distro

The script must be able to write to `/mnt/efi` and `/dev/nvme0n1p6`. Make sure both are accessible from the host context.
