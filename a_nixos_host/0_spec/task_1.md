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

---

═══════════════════════════════════════════════════════════════════════════════
                            WORK LOG
═══════════════════════════════════════════════════════════════════════════════

## 2026-01-08: ISO Build Success + PAM Bug Fix

### Achievements

**1. ISO Build Completed**
- Successfully built NixOS ISO (~4.4GB) using `nix build .#iso`
- Used squashfs format (workaround for raw-efi QEMU I/O errors on low-RAM systems)
- Kernel cached from previous build - no recompilation needed

**2. Critical PAM Bug Fixed**
- **Problem**: SDDM and TTY login failed with "Permission denied" while SSH worked
- **Root Cause**: `security.pam.services.login.text = lib.mkAfter` REPLACES entire PAM config instead of appending
- **Impact**: `/etc/pam.d/login` only had our bluetooth hook, missing auth/account/password entries
- **Fix**: Removed broken PAM entries from configuration.nix (lines 483-490)
- **Lesson**: Never use `.text` for PAM in NixOS - it replaces, not appends!

**3. SDDM Virtual Keyboard Added**
- Added Qt6 virtual keyboard for Surface Pro touchscreen login
- Important: Must use `pkgs.kdePackages.qtvirtualkeyboard` (Qt6), NOT `libsForQt5` (Qt5)
- Qt5/Qt6 mismatch causes build failure with Plasma 6

**4. VM Testing Verified**
- Created VM in virt-manager with UEFI (no Secure Boot)
- SDDM login works: `diego` / `1234567890`
- KDE Plasma 6 desktop loads correctly
- All applications accessible

### Files Modified
- `configuration.nix` - Removed broken PAM entries, added SDDM virtual keyboard
- `flake.nix` - ISO format added with password overrides
- `0_spec/architecture.md` - Added "Known Issues & Fixes" section
- `.gitignore` - Created to exclude `result` symlink

### Next Steps
- [ ] Test on actual Surface Pro 8 hardware
- [ ] Implement bluetooth portable pairings via systemd user service (not PAM)
- [ ] Try raw-efi build on machine with more RAM
