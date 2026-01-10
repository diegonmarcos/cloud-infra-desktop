# MyShell - Operations Runbook

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Building Profiles](#building-profiles)
4. [Running MyShell](#running-myshell)
5. [Distribution](#distribution)
6. [Maintenance](#maintenance)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### System Requirements

| Requirement | Value |
|-------------|-------|
| OS | Linux (kernel 4.4+) |
| Architecture | x86_64 or ARM64 |
| Shell | Any POSIX `/bin/sh` |
| Disk | 200MB - 3GB (varies by profile) |
| Network | Required for first build only |

### Verify System

```bash
# Check architecture
uname -m
# Expected: x86_64 or aarch64

# Check kernel
uname -r
# Expected: 4.4+ (for user namespaces)

# Check POSIX shell
ls -la /bin/sh
```

---

## Installation

### 1. Clone Repository

```bash
git clone <repo-url> myshell
cd myshell
```

### 2. Download nix-portable

```bash
# x86_64
curl -L https://github.com/DavHau/nix-portable/releases/latest/download/nix-portable-$(uname -m) \
  -o bin/nix-portable

# Make executable
chmod +x bin/nix-portable
```

### 3. Verify Installation

```bash
ls -la bin/nix-portable
# Should show ~65MB executable
```

---

## Building Profiles

### Build Single Profile

```bash
# Shell Profile (~200MB)
./build.sh shell

# Minimum Profile (~500MB)
./build.sh minimum

# Basic Profile (~2-3GB)
./build.sh basic
```

### Build All Profiles

```bash
./build.sh all
```

### Build Output

```bash
ls -la dist/
# dist/shell/    (~200MB)
# dist/minimum/  (~500MB)
# dist/basic/    (~2-3GB)
```

### Build Duration

| Profile | First Build | Rebuild |
|---------|-------------|---------|
| shell | 2-5 min | 1 min |
| minimum | 5-10 min | 1 min |
| basic | 15-30 min | 2 min |

*Times vary based on network speed and disk performance.*

---

## Running MyShell

### Start Shell (Default: Fish, Isolated)

```bash
./dist/minimum/myshell
```

### Start with Mirror Mode

```bash
./dist/minimum/myshell --mirror
# or
./dist/minimum/myshell -m
```

### Start with Different Shell

```bash
./dist/minimum/myshell --zsh
./dist/minimum/myshell --bash
./dist/minimum/myshell --fish  # default
```

### Run Single Command

```bash
./dist/minimum/myshell -c "eza -la"
./dist/minimum/myshell -c "git status"
```

### Use Shortcuts

```bash
./dist/minimum/fish-shell    # Same as: myshell --fish
./dist/minimum/zsh-shell     # Same as: myshell --zsh
```

### Exit MyShell

```bash
exit
# or Ctrl+D
```

---

## Distribution

### Create Portable Archive

```bash
# Create tarball
tar czf myshell-minimum.tar.gz dist/minimum/

# Check size
ls -lh myshell-minimum.tar.gz
```

### Deploy to Target System

```bash
# Copy to target
scp myshell-minimum.tar.gz user@target:~/

# On target system
ssh user@target
tar xzf myshell-minimum.tar.gz
./dist/minimum/myshell
```

### Recommended Distribution

| Use Case | Profile | Size |
|----------|---------|------|
| Quick shell tools | shell | ~200MB |
| Development | minimum | ~500MB |
| Full environment | basic | ~2-3GB |

---

## Maintenance

### Clean Build Artifacts

```bash
# Remove specific profile
rm -rf dist/shell/

# Remove all builds
rm -rf dist/
```

### Clean Nix Cache

```bash
# Remove global nix-portable cache
rm -rf ~/.nix-portable

# This forces re-download on next build
```

### Update nix-portable

```bash
# Download latest version
curl -L https://github.com/DavHau/nix-portable/releases/latest/download/nix-portable-$(uname -m) \
  -o bin/nix-portable.new

# Replace old binary
mv bin/nix-portable.new bin/nix-portable
chmod +x bin/nix-portable

# Rebuild profiles
./build.sh all
```

### Update Packages

Packages are pinned by nix-portable. To update:

1. Download new nix-portable (above)
2. Rebuild profiles
3. New package versions will be fetched

---

## Troubleshooting

### Problem: Permission Denied

```bash
# Symptom
./dist/minimum/myshell
-bash: ./dist/minimum/myshell: Permission denied

# Solution
chmod +x dist/minimum/myshell
chmod +x dist/minimum/fish-shell
chmod +x dist/minimum/zsh-shell
```

### Problem: First Run Very Slow

**Expected behavior.** First run downloads packages to Nix store.

```bash
# Check progress
tail -f ~/.nix-portable/nix/var/log/nix/*.log
```

### Problem: nix-portable Not Found

```bash
# Symptom
./build.sh shell
✗ nix-portable not found at bin/nix-portable

# Solution
curl -L https://github.com/DavHau/nix-portable/releases/latest/download/nix-portable-$(uname -m) \
  -o bin/nix-portable
chmod +x bin/nix-portable
```

### Problem: Command Not Found Inside MyShell

```bash
# Symptom
$ rg pattern
fish: Unknown command: rg

# Cause: Using wrong profile
# Solution: Use minimum or basic profile
./dist/minimum/myshell
```

### Problem: Disk Full During Build

```bash
# Check disk space
df -h

# Clean caches
rm -rf ~/.nix-portable
rm -rf dist/

# Rebuild with smaller profile
./build.sh shell
```

### Problem: User Namespace Not Supported

```bash
# Symptom
nix-portable: user namespaces not supported

# Check kernel config
cat /proc/sys/kernel/unprivileged_userns_clone
# Should be: 1

# Enable (requires root)
sudo sysctl kernel.unprivileged_userns_clone=1

# Persist
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/99-userns.conf
```

### Problem: Store Corruption

```bash
# Symptom
error: path '...' is corrupted

# Solution: Clean and rebuild
rm -rf ~/.nix-portable
rm -rf dist/
./build.sh all
```

---

## Quick Reference

### Common Commands

| Task | Command |
|------|---------|
| Build minimum profile | `./build.sh minimum` |
| Start shell (isolated) | `./dist/minimum/myshell` |
| Start shell (mirror) | `./dist/minimum/myshell -m` |
| Run command | `./dist/minimum/myshell -c "cmd"` |
| Create archive | `tar czf myshell.tar.gz dist/minimum/` |
| Clean builds | `rm -rf dist/` |
| Clean cache | `rm -rf ~/.nix-portable` |

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `NIX_PORTABLE_ROOT` | Nix store location | `~/.nix-portable` |
| `ISOLATION_MODE` | true/false | `true` |
| `HOME` | Home directory | Depends on mode |
| `REAL_HOME` | Original home | `/home/user` |

### File Locations

| File | Purpose |
|------|---------|
| `bin/nix-portable` | Nix binary |
| `src/*-profile.nix` | Profile definitions |
| `dist/<profile>/myshell` | Launcher script |
| `dist/<profile>/_bundled/` | Bundled store |
| `~/.nix-portable/` | Global Nix cache |
| `~/.temp/home-tmp/` | Isolated home |

---

## Support

- **README.md** - User documentation
- **SPEC.md** - Architecture design
- **Issues** - Report problems via repository issues
