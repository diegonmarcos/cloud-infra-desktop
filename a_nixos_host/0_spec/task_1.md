# Task 1: Repair NixOS from Kubuntu

> **Status**: Pending
> **ETA**: 5-8 minutes
> **Downloads**: Minimal (deps cached)

---

## Problem

NixOS system derivation **missing from store**:
```
/nix/store/pl0y29z2i540q27fh63q1m9kw21jwgvn-nixos-system-surface-nixos-24.11.20250630.50ab793
```
GRUB references it but it was garbage collected. Booting NixOS = kernel panic.

---

## Solution: Build Directly into @nixos Store

Use Kubuntu as recovery environment. Mount existing nix store, rebuild in place.

---

## Steps

### Step 1: Mount Existing Store (5 sec)
```bash
sudo mkdir -p /nix
sudo mount --bind /pool/@nixos/nix /nix
```

### Step 2: Start Nix Daemon (1-2 min)
```bash
# Install nix if not present
curl -L https://nixos.org/nix/install | sh -s -- --daemon

# Or if nix binary exists in store, use directly:
sudo /nix/store/*-nix-*/bin/nix-daemon &
```

### Step 3: Build NixOS System (3-5 min)
```bash
cd /home/diego/mnt_git/unix/a_nixos_host
nix build .#nixosConfigurations.surface.config.system.build.toplevel
```
- Reuses 26GB cached deps
- Only rebuilds initrd (new module order)
- Output: `./result` symlink

### Step 4: Activate New System (1 min)
```bash
# Get new system path
NEW_SYSTEM=$(readlink -f ./result)
echo "New system: $NEW_SYSTEM"

# Update system profile
sudo nix-env -p /nix/var/nix/profiles/system --set ./result

# Copy boot files
sudo cp -f ./result/kernel /boot/nixos/vmlinuz
sudo cp -f ./result/initrd /boot/nixos/initrd

# CRITICAL: Update GRUB init= path (fixes boot!)
OLD_INIT="init=/nix/store/pl0y29z2i540q27fh63q1m9kw21jwgvn-nixos-system-surface-nixos-24.11.20250630.50ab793/init"
NEW_INIT="init=${NEW_SYSTEM}/init"
sudo sed -i "s|${OLD_INIT}|${NEW_INIT}|" /boot/grub/grub.cfg

# Verify the fix
grep "init=" /boot/grub/grub.cfg | grep nixos
```

### Step 5: Cleanup
```bash
sudo umount /nix
```

---

## Verification

After reboot into NixOS:
```bash
# Check kernel modules loaded
lsmod | grep surface

# Expected order:
# intel_lpss -> surface_aggregator -> surface_hid

# Test keyboard
# Type Cover should work!
```

---

## Disk Space

| Location | Size | Free |
|----------|------|------|
| Pool (btrfs) | 80GB | 40GB |
| @nixos/nix/store | 26GB | - |
| Kubuntu / | 116GB | 43GB |

No duplication - build directly into target store.

---

## Rollback

If build fails:
```bash
sudo umount /nix
# Kubuntu unaffected
```

If NixOS still broken after rebuild:
- Boot Kubuntu
- Re-run build with fixes
