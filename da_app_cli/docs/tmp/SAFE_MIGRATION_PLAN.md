# Safe Migration Plan - Kubuntu to Containers

**CRITICAL**: This plan ensures the Kubuntu KDE system remains functional throughout migration.

---

## Safety Principles

1. ✅ **Test containers BEFORE removing system packages**
2. ✅ **Keep essential KDE/system packages**
3. ✅ **Create backups before each step**
4. ✅ **Migrate incrementally (one tool at a time)**
5. ✅ **Verify functionality after each migration**
6. ✅ **Keep rollback capability**

---

## PHASE 1: ✅ COMPLETE

- [x] app_cli container ready (Nix-based)
- [x] app_gui container ready (Flatpak-based)
- [x] Docker cleanup done (-6.27 GB)
- [x] VM software analysis done (no images on system)

---

## PHASE 2: ✅ COMPLETE - System Snapshots Created

### Backups Created (in ~/migration_backups/)
- `apt_manual_packages_before.txt` - 497 packages
- `snap_packages_before.txt` - 6 snap packages
- `docker_containers_before.txt` - Container states
- `docker_images_before.txt` - Image list
- `disk_usage_before.txt` - Disk usage
- `docker_size_before.txt` - Docker storage size

### Rollback Capability
If anything breaks:
```bash
# Reinstall a package
sudo apt install <package-name>

# Reinstall from list
cat ~/migration_backups/apt_manual_packages_before.txt | xargs sudo apt install
```

---

## PHASE 3: CLI Tools Migration (SAFE)

### What We'll Migrate

#### CLI Development Tools (to app_cli Nix)
```
✓ git           - Version control
✓ nodejs        - JavaScript runtime
✓ npm           - Node package manager
✗ make          - Keep on system (build essential)
✗ docker        - Keep on system (daemon needs host)
✗ podman        - Keep on system (daemon needs host)
```

#### CLI Utilities (to app_cli Nix)
```
✓ btop          - System monitor
✓ htop          - System monitor
✓ ncdu          - Disk usage
✓ tree          - Directory tree
✓ vim           - Text editor
✓ curl          - HTTP client (install in Nix too)
✓ rsync         - File sync (install in Nix too)
✓ zip/unzip     - Archive tools
```

#### What to KEEP on System (DO NOT REMOVE)
```
✗ bash          - System shell
✗ zsh           - Shell
✗ systemd       - Init system
✗ network-manager - Network
✗ ufw           - Firewall
✗ openssh       - SSH client/server
✗ grub          - Bootloader
✗ Any package starting with: kde-, plasma-, qt5-, kubuntu-
✗ Any package starting with: lib* (libraries)
✗ gcc/g++       - Maybe keep for system builds
```

### Migration Steps (ONE TOOL AT A TIME)

#### Step 3.1: Test app_cli Container
```bash
# Enter container
distrobox enter dev

# Verify Nix works
which git nodejs npm

# Test a tool
git --version

# Exit
exit
```

#### Step 3.2: Migrate Non-Essential CLI Tools (Safe)
**Tools to migrate**: btop, ncdu, tree

```bash
# 1. Test in container FIRST
distrobox enter dev
btop --version  # Should work (already in Nix)
ncdu --version
tree --version
exit

# 2. Export to host (optional - use from container)
distrobox enter dev -- distrobox-export --bin /usr/bin/btop

# 3. Only AFTER confirming container works
sudo apt remove btop ncdu tree

# 4. Test it still works
distrobox enter dev -- btop
```

#### Step 3.3: Migrate Development Tools (Careful)
**Tools**: nodejs, npm

```bash
# 1. Check what depends on them
apt rdepends nodejs npm

# 2. Test in container
distrobox enter dev
node --version
npm --version

# 3. Remove from system ONLY if no critical dependencies
sudo apt remove nodejs npm

# 4. Verify system still works (open apps, test desktop)
```

#### Step 3.4: Keep Docker/Podman on System
**DO NOT REMOVE** - These are system daemons needed to run containers!

---

## PHASE 4: GUI Apps Migration (SAFER - Flatpak isolates everything)

### Current Snap Apps (to migrate to Flatpak)
```
firefox  → org.mozilla.firefox (Flatpak)
```

### Migration Steps

#### Step 4.1: Test app_gui Container
```bash
# Enter container
distrobox enter flatpak-box

# List installed flatpaks
flatpak list

# Test an app
flatpak run com.brave.Browser

# Exit
exit
```

#### Step 4.2: Migrate Firefox (Safe - Browser)
```bash
# 1. Install Firefox in Flatpak container
distrobox enter flatpak-box
flatpak install flathub org.mozilla.firefox
flatpak run org.mozilla.firefox  # Test it works
exit

# 2. Export to desktop menu
distrobox enter flatpak-box -- distrobox-export --app org.mozilla.firefox

# 3. Test from host menu (click Firefox icon)

# 4. Only AFTER confirming Flatpak works:
snap remove firefox

# 5. Verify it still launches from menu
```

#### Step 4.3: Migrate VSCode (if installed)
```bash
# 1. Check if installed
which code

# 2. Install in Flatpak
distrobox enter flatpak-box
flatpak install flathub com.visualstudio.code
exit

# 3. Export and test before removing system version
```

### What to KEEP as System Apps (DO NOT FLATPAK)
```
✗ Konsole       - KDE terminal (system integration)
✗ Dolphin       - KDE file manager (system integration)
✗ Kate          - KDE editor (system integration)
✗ System Settings - KDE settings (system critical)
✗ SDDM          - Display manager
```

---

## PHASE 5: System Cleanup (AFTER successful migration)

### Only Remove After Verification

```bash
# 1. Verify containers work for 1 week

# 2. Remove migrated CLI tools
sudo apt remove btop htop ncdu tree vim

# 3. Check for orphaned dependencies
sudo apt autoremove

# 4. Remove unused snaps
sudo snap remove gnome-42-2204 gtk-common-themes

# 5. Clean cache
sudo apt clean
rm -rf ~/.cache/*
```

### What to NEVER Remove
```
✗ kubuntu-desktop     - Desktop metapackage
✗ kde-plasma-desktop  - KDE desktop
✗ sddm                - Display manager
✗ network-manager     - Networking
✗ systemd             - Init
```

---

## PHASE 6: Verification & Cleanup

### Verification Checklist
- [ ] Desktop environment works (KDE Plasma)
- [ ] Login works (SDDM)
- [ ] Network works
- [ ] Containers start on boot
- [ ] All tools accessible in containers
- [ ] Desktop apps launch from menu
- [ ] No errors in journalctl

### Cleanup
```bash
# After 1 week of successful operation:

# 1. Clean Docker again (if needed)
docker system prune

# 2. Clean old kernels (if any)
sudo apt autoremove

# 3. Verify disk space gained
df -h
```

---

## Testing Protocol

### Before Removing ANY Package

1. **Check dependencies**:
   ```bash
   apt rdepends <package>
   apt-cache rdepends <package>
   ```

2. **Simulate removal**:
   ```bash
   sudo apt remove --simulate <package>
   ```

3. **Check what else would be removed**:
   - If it wants to remove KDE/plasma/kubuntu packages → STOP!
   - If only the package itself → Probably safe

4. **Test in container first**:
   ```bash
   distrobox enter dev  # or flatpak-box
   <use the tool>
   ```

5. **Only remove if**:
   - Tool works in container
   - No KDE dependencies
   - System simulation looks safe

---

## Rollback Procedures

### If Desktop Breaks
```bash
# From TTY (Ctrl+Alt+F2)
sudo apt install kubuntu-desktop kde-plasma-desktop

# Reinstall display manager
sudo apt install --reinstall sddm

# Restart display manager
sudo systemctl restart sddm
```

### If Tool Missing
```bash
# Quick fix: Install from backup list
cat ~/migration_backups/apt_manual_packages_before.txt | grep <tool> | xargs sudo apt install

# Or use container
distrobox enter dev -- <command>
```

### If Container Breaks
```bash
# Recreate app_cli
cd ~/app_cli
./scripts/setup.sh full

# Recreate app_gui
cd ~/app_gui
./setup.sh all
```

---

## Risk Assessment

### Low Risk (Safe to Migrate)
- btop, htop, ncdu (monitoring tools)
- tree, vim, zip/unzip (utilities)
- Development tools (nodejs, npm) - after testing

### Medium Risk (Test Carefully)
- Firefox snap → Flatpak (test profile migration)
- VSCode (if installed)

### HIGH RISK (DO NOT TOUCH)
- kde-*, plasma-*, kubuntu-* packages
- sddm, systemd, network-manager
- docker, podman (system daemons)
- bash, zsh (shells)
- grub (bootloader)
- lib* packages (libraries)

---

## Success Criteria

### After Complete Migration
- [ ] System boots normally
- [ ] KDE Plasma works
- [ ] Login works
- [ ] Network works
- [ ] Containers start automatically
- [ ] All CLI tools available in app_cli
- [ ] All GUI apps available in app_gui
- [ ] Desktop menu shows flatpak apps
- [ ] No functionality lost
- [ ] System is clean (minimal packages)

### Storage Goals
- Before: 75 GB used
- After cleanup: ~55 GB used
- Recovery target: ~20 GB

**Current**: 71 GB used (4 GB recovered from Docker cleanup)
**Remaining**: 16 GB to recover from system cleanup

---

## Next Steps

**Phase 3 Start**: Test app_cli container with current tools

Ready to proceed? (y/n)
