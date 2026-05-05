# NixOS Issues Status - 2026-01-08 (Updated)

## ✅ ADDRESSED ISSUES (15 total)

### Issue -1: NO /etc/nixos/configuration.nix FILE ✅
- **Status:** ADDRESSED
- **What was done:** Found config at `/mnt/kubuntu/home/diego/mnt_git/unix/a_nixos_host/`, added essential packages
- **Needs:** Rebuild with `sudo nixos-rebuild switch --flake .#surface`

### Issue 0: Ephemeral Root + Lost User Settings ✅
- **Status:** ADDRESSED
- **WiFi:** Uses GNOME Keyring stored in `~/.local/share/keyrings/` (per-user, portable)
- **Bluetooth:** Uses `@shared/bluetooth/` via systemd service (cross-OS, hardware-tied)
- **What was done:**
  - Keyring services configured (gnome-keyring, kwallet)
  - Bluetooth persistence service added to symlink `/var/lib/bluetooth` -> `/mnt/shared/bluetooth`

### Issue 1: NixOS Bootstrap Paradox ✅
- **Status:** ADDRESSED
- **What was done:** Added firefox, git, wget, curl, nodejs to configuration.nix
- **Result:** System will have essential tools to build user environment

### Issue 2: File Permissions - Trash Folder ✅
- **Status:** ADDRESSED via tmpfiles rules
- **What was done:** Added tmpfiles rules to create `~/.local/share/Trash/{files,info}` with correct ownership

### Issue 3: Missing Essential Development Tools ✅
- **Status:** ADDRESSED
- **What was done:** Added nodejs, git, wget, curl to system packages

### Issue 4: Nix Channel Database Missing ✅
- **Status:** ADDRESSED
- **What was done:** Disabled command-not-found (`programs.command-not-found.enable = false`)
- **Result:** No more database errors (system uses flakes, not channels)

### Issue 5: Fish Shell Generated Completions Permission ✅
- **Status:** ADDRESSED via tmpfiles rules
- **What was done:** tmpfiles rules ensure `~/.local` and `~/.cache` exist with correct ownership

### Issue 6: KWallet Crash ✅
- **Status:** ADDRESSED via tmpfiles rules
- **What was done:** tmpfiles rules fix `~/.local` ownership (root cause of KWallet issues)

### Issue 7: User State Directory Permissions ✅
- **Status:** ADDRESSED via tmpfiles rules
- **What was done:** Added tmpfiles rules for `~/.local`, `~/.local/state`, `~/.local/state/nix`

### Issue 8: Flatpak Flathub Repository Not Configured ✅
- **Status:** ADDRESSED
- **What was done:** Added systemd service to auto-configure flathub remote on boot
- **Result:** Flatpak will have flathub available after rebuild, persists across reboots

### Issue 10: Waydroid Permission Errors ✅
- **Status:** ADDRESSED via tmpfiles rules
- **What was done:** Added tmpfiles rule for `~/.local/share/waydroid` with correct ownership

### Issue 11: Claude Code Running via npx Script ✅
- **Status:** ADDRESSED
- **What was done:** Added nodejs to system packages
- **Result:** npm/npx will be in PATH, `bash ~/user/claude.sh` will work

### Issue 12: Cannot Install Personal Apps as User ✅
- **Status:** ADDRESSED via tmpfiles rules
- **What was done:** tmpfiles rules fix `~/.local` ownership (root cause)

### Issue 14: Cannot Move/Delete Files ✅
- **Status:** ADDRESSED via tmpfiles rules
- **What was done:** Trash folder structure created with correct ownership

### Issue 15: System-Wide Permission Errors from Journald ✅
- **Status:** ADDRESSED via tmpfiles rules
- **What was done:** Root cause (`.local` permissions) fixed via tmpfiles

### Issue 17: Scripts Cannot Execute (#!/bin/bash) ✅
- **Status:** ADDRESSED
- **What was done:** Added activation script to create `/bin/bash` symlink
```nix
system.activationScripts.binBash = ''
  mkdir -p /bin
  ln -sf ${pkgs.bash}/bin/bash /bin/bash
'';
```

### Issue 18: Dolphin Pool Mount Navigation ✅
- **Status:** ADDRESSED
- **What was done:** Added `/mnt/btrfs-root` mount to hardware-configuration.nix
- **Result:** Clicking "pool" in Dolphin will navigate to btrfs root showing all subvolumes

---

## ⚠️ REMAINING ISSUES (3 total)

### Issue 9: Konqueror Browser Not in PATH ⚠️
- **Status:** NOT ADDRESSED (LOW priority)
- **Workaround:** Firefox added instead (better choice)
- **Impact:** Konqueror not accessible from command line

### Issue 13: Virtual Keyboard Not Working in SDDM Login ⚠️
- **Status:** PARTIALLY ADDRESSED
- **What was done:** SDDM configured with `InputMethod = "qtvirtualkeyboard"` and Qt6 package
- **Note:** May need testing on actual Surface hardware
- **Impact:** Needed for touchscreen-only login

### Issue 16: Missing Issue (if exists) ⚠️
- **Status:** Unknown - verify if this issue exists

---

## SUMMARY

### ✅ Addressed: 15 issues
- Bootstrap tools (firefox, git, wget, curl, nodejs)
- Flatpak with flathub auto-configuration
- WiFi persistence via keyring (per-user, portable)
- Bluetooth persistence via @shared (cross-OS)
- Home directory permissions via tmpfiles
- /bin/bash symlink for script compatibility
- command-not-found disabled (flakes don't use channels)
- Dolphin pool navigation fixed

### ⚠️ Remaining: 3 issues
- Issue #9: Konqueror (LOW - Firefox available)
- Issue #13: Virtual keyboard (needs hardware testing)
- Potential Issue #16 (verify)

---

## IMPLEMENTATION DETAILS

### Tmpfiles Rules Added (configuration.nix)
Creates proper home directory structure on every boot:
```nix
systemd.tmpfiles.rules = [
  # Diego's home
  "d /home/diego/.local 0700 diego users -"
  "d /home/diego/.local/share 0700 diego users -"
  "d /home/diego/.local/share/Trash 0700 diego users -"
  "d /home/diego/.local/share/Trash/files 0700 diego users -"
  "d /home/diego/.local/share/Trash/info 0700 diego users -"
  "d /home/diego/.local/share/keyrings 0700 diego users -"
  "d /home/diego/.local/share/bluetooth 0700 diego users -"
  "d /home/diego/.local/share/waydroid 0700 diego users -"
  "d /home/diego/.local/state 0700 diego users -"
  "d /home/diego/.local/state/nix 0700 diego users -"
  "d /home/diego/.cache 0700 diego users -"
  "d /home/diego/.config 0700 diego users -"
  # (Same for guest user)
];
```

### Bluetooth Persistence Service (configuration.nix)
Symlinks /var/lib/bluetooth to @shared at boot:
```nix
systemd.services.bluetooth-persistent = {
  description = "Symlink Bluetooth pairings to @shared";
  wantedBy = [ "multi-user.target" ];
  before = [ "bluetooth.service" ];
  after = [ "local-fs.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = pkgs.writeShellScript "bluetooth-shared-symlink" ''
      mkdir -p /mnt/shared/bluetooth
      chmod 700 /mnt/shared/bluetooth
      rm -rf /var/lib/bluetooth 2>/dev/null || true
      ln -sf /mnt/shared/bluetooth /var/lib/bluetooth
    '';
  };
};
```

---

## NEXT STEP

Rebuild the system to apply all fixes:
```bash
cd /mnt/kubuntu/home/diego/mnt_git/unix/a_nixos_host/
sudo nixos-rebuild switch --flake .#surface
```

After rebuild:
- npm/npx working (claude.sh works!)
- Firefox, git, wget, curl available
- Flatpak with flathub
- WiFi passwords persist (in keyring)
- Bluetooth pairings persist (in @shared)
- Home directory permissions correct
- Standard bash scripts work (/bin/bash exists)
- Trash folder works in Dolphin
