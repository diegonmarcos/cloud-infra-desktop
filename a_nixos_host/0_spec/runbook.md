# NixOS Bifrost Runbook

## Quick Reference

| Credential | Value |
|------------|-------|
| **User** | `user` |
| **Password** | `1234567890` |
| **SSH** | `ssh user@<IP>` (password enabled) |

## Available Sessions

| Session | Type | Description |
|---------|------|-------------|
| **Plasma (KDE)** | Wayland | Full desktop environment (default) |
| **Openbox** | X11 | Lightweight window manager |
| **Android (Waydroid)** | Wayland | Full Android UI via Waydroid |
| **Tor Kiosk** | Wayland | Tor Browser in kiosk mode |
| **Chrome Kiosk** | Wayland | Chromium in kiosk mode |
| **ChromiumOS Style** | Wayland | Minimal Chrome-centric desktop |

---

## BUILD PROCEDURES

### Step 1: Build QCOW2 for VM Testing

```bash
cd /home/diego/mnt_git/unix/a_nixos_host
./build.sh build qcow
```

Output: `/mnt/kinoite/@images/a_nixos_host/2_raw/nixos.qcow2`

### Step 2: Test in VM

```bash
./build.sh vm nixos-test
```

Or manually:
```bash
virt-install \
  --name nixos-test \
  --ram 4096 \
  --vcpus 2 \
  --disk path=/mnt/kinoite/@images/a_nixos_host/2_raw/nixos.qcow2,format=qcow2 \
  --import \
  --os-variant nixos-unstable \
  --network default \
  --graphics spice \
  --boot uefi
```

### Step 3: Build Raw Image (for USB/disk installation)

```bash
./build.sh build raw
```

Output: `/mnt/kinoite/@images/a_nixos_host/2_raw/nixos.raw`

### Step 4: Burn to USB

```bash
./build.sh burn /dev/sdX
```

### Step 5: Full Installation to Disk

```bash
sudo TARGET_DISK=/dev/nvme0n1 ./build.sh install
```

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
sudo nixos-rebuild switch --flake /etc/nixos#surface
```

### Rollback to Previous Generation

```bash
# List generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Boot menu: Select previous generation
# Or manually:
sudo nixos-rebuild switch --rollback
```

---

## TROUBLESHOOTING

### QCOW2 Build Fails

1. Check nix version:
```bash
nix --version
```

2. Verify flakes enabled:
```bash
nix flake show .
```

3. Check configuration:
```bash
nix flake check .
```

### VM Won't Start

1. Check libvirt:
```bash
sudo systemctl status libvirtd
```

2. Check UEFI support:
```bash
ls /usr/share/OVMF/
```

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

---

## FILE LOCATIONS

| File | Path |
|------|------|
| **Scripts** | `/home/diego/mnt_git/unix/a_nixos_host/` |
| **Build Output** | `/mnt/kinoite/@images/a_nixos_host/2_raw/` |
| **Flake** | `/home/diego/mnt_git/unix/a_nixos_host/flake.nix` |
| **Configuration** | `/home/diego/mnt_git/unix/a_nixos_host/configuration.nix` |
