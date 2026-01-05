# NixOS Bifrost Runbook

## Quick Reference

| Credential | Value |
|------------|-------|
| **User** | `user` |
| **Password** | `1234567890` |
| **SSH** | `ssh user@<IP>` (password enabled) |
| **LUKS** | Same as user password |

## Available Sessions

| Session | Type | Description |
|---------|------|-------------|
| **Plasma (KDE)** | Wayland | Full desktop environment (default) |
| **GNOME** | Wayland | Alternative full desktop |
| **Openbox** | X11 | Lightweight window manager |
| **Android (Waydroid)** | Wayland | Full Android UI via Waydroid |
| **Tor Kiosk** | Wayland | Tor Browser in kiosk mode |
| **Chrome Kiosk** | Wayland | Chromium in kiosk mode |

---

## INITIAL INSTALLATION (Completed 2026-01-05)

### Prerequisites (on Kubuntu)

1. Install Nix package manager:
```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
```

2. Enable flakes in `/etc/nix/nix.conf`:
```
experimental-features = nix-command flakes
```

3. Mount LUKS pool and bind /nix:
```bash
sudo cryptsetup open /dev/nvme0n1p4 pool
sudo mount /dev/mapper/pool /mnt/pool
sudo mount --bind /mnt/pool/@shared/nix /nix
```

### Step 1: Build Raw Image

```bash
cd /home/diego/mnt_git/unix/a_nixos_host
nix build .#raw --out-link /mnt/nixos/result
```

Build time: ~2 hours on Surface Pro 8 (4 cores, 8 threads)
Output: `/mnt/nixos/result/nixos.img` (27.6 GB)

### Step 2: Mount and Extract Image

```bash
# Attach image
sudo losetup -fP /mnt/nixos/result/nixos.img
sudo mount /dev/loop0p2 /mnt/nixos-img

# Copy kernel and initrd
sudo mkdir -p /boot/nixos
sudo cp -L /nix/store/hmj4damlkx7pp4b4dsh1yqbw3w91p0sc-nixos-system-*/kernel /boot/nixos/vmlinuz
sudo cp -L /nix/store/hmj4damlkx7pp4b4dsh1yqbw3w91p0sc-nixos-system-*/initrd /boot/nixos/initrd
```

### Step 3: Copy Nix Store Closure

```bash
# Get closure paths
nix-store -qR /nix/store/hmj4damlkx7pp4b4dsh1yqbw3w91p0sc-nixos-system-* > /tmp/nixos-closure.txt

# Copy to @root-nixos/nix (uses btrfs reflinks - instant, no extra space)
xargs -a /tmp/nixos-closure.txt -I {} sudo cp -a --reflink=auto {} /mnt/pool/@root-nixos/nix/store/
```

### Step 4: Set Up Profiles

```bash
sudo mkdir -p /mnt/pool/@root-nixos/nix/var/nix/profiles
sudo ln -sf /nix/store/hmj4damlkx7pp4b4dsh1yqbw3w91p0sc-nixos-system-* /mnt/pool/@root-nixos/nix/var/nix/profiles/system-1-link
sudo ln -sf system-1-link /mnt/pool/@root-nixos/nix/var/nix/profiles/system
```

### Step 5: Set Up Persist

```bash
# Create directory structure
sudo mkdir -p /mnt/pool/@root-nixos/persist/{var/lib/nixos,var/lib/systemd,var/lib/bluetooth,var/lib/NetworkManager,var/log,etc/NetworkManager/system-connections,etc/ssh}
sudo mkdir -p /mnt/pool/@root-nixos/persist/home/user/{.config,.local,.cache,.ssh,.gnupg,Documents,Downloads,Projects}

# Generate machine-id
sudo sh -c 'uuidgen | tr -d - > /mnt/pool/@root-nixos/persist/etc/machine-id'

# Generate SSH host keys
sudo ssh-keygen -t ed25519 -f /mnt/pool/@root-nixos/persist/etc/ssh/ssh_host_ed25519_key -N ""
sudo ssh-keygen -t rsa -b 4096 -f /mnt/pool/@root-nixos/persist/etc/ssh/ssh_host_rsa_key -N ""
```

### Step 6: Add GRUB Entry

```bash
cat << 'EOF' | sudo tee /etc/grub.d/40_nixos
#!/bin/sh
exec tail -n +3 $0

menuentry "NixOS" --class nixos --class gnu-linux --class os {
    insmod gzio
    insmod part_gpt
    insmod btrfs
    insmod cryptodisk
    insmod luks2

    search --no-floppy --fs-uuid --set=root 0eaf7961-48c5-4b55-8a8f-04cd0b71de07

    linux /nixos/vmlinuz init=/nix/store/pl0y29z2i540q27fh63q1m9kw21jwgvn-nixos-system-surface-nixos-24.11.20250630.50ab793/init loglevel=4
    initrd /nixos/initrd
}
EOF

sudo chmod +x /etc/grub.d/40_nixos
sudo update-grub
```

### Step 7: Cleanup and Boot

```bash
sudo umount /mnt/nixos-img
sudo losetup -d /dev/loop0

# Reboot and select NixOS from GRUB
sudo reboot
```

---

## BOOTING NIXOS

1. Power on Surface Pro 8
2. GRUB menu appears
3. Select **"NixOS"**
4. Enter LUKS password when prompted
5. SDDM login appears
6. Login: `user` / `1234567890`
7. Select session (Plasma, GNOME, Openbox, etc.)

---

## POST-INSTALLATION PROCEDURES

### Initialize Waydroid (Android)

First boot after installation:
```bash
sudo waydroid init
waydroid session start
waydroid show-full-ui
```

### Setup Flatpak

```bash
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install flathub com.visualstudio.code
```

### Update System

```bash
cd /home/diego/mnt_git/unix/a_nixos_host
sudo nixos-rebuild switch --flake .#surface
```

### Rollback to Previous Generation

```bash
# List generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Rollback
sudo nixos-rebuild switch --rollback

# Or select from GRUB boot menu
```

---

## TROUBLESHOOTING

### NixOS Won't Boot

1. Check GRUB entry exists:
```bash
sudo grep "NixOS" /boot/grub/grub.cfg
```

2. Check kernel/initrd exist:
```bash
ls -la /boot/nixos/
```

3. Check system store path exists:
```bash
ls /mnt/pool/@root-nixos/nix/store/hmj4damlkx7pp4b4dsh1yqbw3w91p0sc-*
```

### LUKS Won't Unlock

The LUKS password is the same as the user password: `1234567890`

If still failing, boot Kubuntu and check:
```bash
sudo cryptsetup open /dev/nvme0n1p4 pool
```

### No Network After Boot

1. Check NetworkManager:
```bash
systemctl status NetworkManager
```

2. WiFi connections should persist in `/persist/etc/NetworkManager/system-connections/`

### Session Not Appearing in SDDM

1. Check session files:
```bash
ls -la /run/current-system/etc/wayland-sessions/
```

2. Restart SDDM:
```bash
sudo systemctl restart sddm
```

### Waydroid Not Working

1. Check binder modules:
```bash
lsmod | grep binder
```

2. Initialize:
```bash
sudo waydroid init
```

3. Restart:
```bash
waydroid session stop
waydroid session start
```

---

## MAINTENANCE

### Garbage Collection

```bash
# Clean old generations (keep last 5)
sudo nix-collect-garbage --delete-older-than 7d

# Optimize store
sudo nix store optimise
```

### Update Flake Inputs

```bash
cd /home/diego/mnt_git/unix/a_nixos_host
nix flake update
```

### Rebuild with Changes

```bash
sudo nixos-rebuild switch --flake .#surface
```

### Update Kernel/Initrd After Rebuild

After `nixos-rebuild`, update boot files:
```bash
SYSTEM=$(readlink -f /nix/var/nix/profiles/system)
sudo cp -L $SYSTEM/kernel /boot/nixos/vmlinuz
sudo cp -L $SYSTEM/initrd /boot/nixos/initrd

# Update GRUB entry with new init path
sudo sed -i "s|init=/nix/store/[^/]*/init|init=$SYSTEM/init|" /etc/grub.d/40_nixos
sudo update-grub
```

---

## FILE LOCATIONS

| File | Path |
|------|------|
| **Git Repo** | `/home/diego/mnt_git/unix/a_nixos_host/` |
| **Flake** | `/home/diego/mnt_git/unix/a_nixos_host/flake.nix` |
| **Configuration** | `/home/diego/mnt_git/unix/a_nixos_host/configuration.nix` |
| **Hardware Config** | `/home/diego/mnt_git/unix/a_nixos_host/hardware-configuration.nix` |
| **Build Output** | `/mnt/nixos/result/` |
| **Kernel** | `/boot/nixos/vmlinuz` |
| **Initrd** | `/boot/nixos/initrd` |
| **GRUB Entry** | `/etc/grub.d/40_nixos` |
| **Nix Store** | `/mnt/pool/@root-nixos/nix/store/` |
| **Persist** | `/mnt/pool/@root-nixos/persist/` |

---

## STORE PATHS (Current Installation)

| Component | Store Path |
|-----------|------------|
| **System** | `pl0y29z2i540q27fh63q1m9kw21jwgvn-nixos-system-surface-nixos-24.11.20250630.50ab793` |
| **Kernel** | `6qxqvpa0v7is69dvy9y2hikvjzr9r6id-linux-6.12.19` |
| **Initrd** | `jc47rn58hbskcrbrzj52xr8ab6xv0p8b-initrd-linux-6.12.19` |
| **Bash** | `mjhcjikhxps97mq5z54j4gjjfzgmsir5-bash-5.2p37` |
| **Systemd** | `3n52dlrwqb79mc5zcr4nni17dkvaxwa1-systemd-256.10` |

---

## VERIFICATION CHECKLIST

Before rebooting to NixOS, verify:

- [ ] `/boot/nixos/vmlinuz` exists (kernel)
- [ ] `/boot/nixos/initrd` exists (initramfs)
- [ ] GRUB entry in `/boot/grub/grub.cfg`
- [ ] System in `/mnt/pool/@root-nixos/nix/store/`
- [ ] Profile symlink at `/mnt/pool/@root-nixos/nix/var/nix/profiles/system`
- [ ] SSH keys in `/mnt/pool/@root-nixos/persist/etc/ssh/`
- [ ] machine-id in `/mnt/pool/@root-nixos/persist/etc/machine-id`
