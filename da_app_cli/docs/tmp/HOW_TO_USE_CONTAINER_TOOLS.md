# How to Use Tools from app_cli Container

## Current Situation

✅ **The app_cli container IS RUNNING** (Docker container named "dev")
✅ **All tools are AVAILABLE** (git, node, python3, vim, htop, tree)
⚠️ **System tools NOT removed yet** (we stopped before removal)

---

## Why the Container "Isn't Working"

The container IS working, but **distrobox can't see it**. This happens because:
- Container was created with Docker
- Distrobox list is empty (database issue)

**Solution**: Use Docker directly (it works perfectly!)

---

## How to Access Tools (3 Options)

### Option 1: Direct Docker Commands (Simplest)
```bash
# Use tools directly
docker exec dev git status
docker exec dev node script.js
docker exec dev python3 app.py
docker exec dev htop
docker exec dev vim file.txt

# With working directory
docker exec -w /home/diego/my-project dev git commit -m "message"
```

### Option 2: Enter Container Shell (Recommended)
```bash
# Enter the container
docker exec -it dev bash

# Now use tools normally
git status
node --version
vim file.txt

# Exit when done
exit
```

### Option 3: Create Shell Aliases (Convenience)
Add to your `~/.zshrc` or `~/.bashrc`:

```bash
# Container tool aliases
alias cgit='docker exec dev git'
alias cnode='docker exec dev node'
alias cnpm='docker exec dev npm'
alias cpython='docker exec dev python3'
alias chtop='docker exec dev htop'
alias cvim='docker exec dev vim'
alias ctree='docker exec dev tree'

# Enter container
alias dev-shell='docker exec -it dev bash'
```

Then reload:
```bash
source ~/.zshrc
```

Use like:
```bash
cgit status
cnode app.js
dev-shell  # full shell access
```

---

## What Tools Are Available in Container

Confirmed working in the `dev` container:

| Tool | Version | Command |
|------|---------|---------|
| Git | 2.52.0 | `docker exec dev git` |
| Node.js | 22.21.1 | `docker exec dev node` |
| Python | 3.13.9 | `docker exec dev python3` |
| htop | ✓ | `docker exec dev htop` |
| tree | ✓ | `docker exec dev tree` |
| vim | ✓ | `docker exec dev vim` |

Plus many more from the Nix configuration!

---

## What's Still on the System

**We have NOT removed anything yet!** All system tools still work:

```bash
# These still work on your system:
git --version      # System git
node --version     # System node (if installed)
vim file.txt       # System vim
btop               # System btop
htop               # System htop
tree               # System tree
```

---

## Migration Status

| Phase | Status | Action |
|-------|--------|--------|
| Phase 1 | ✅ Complete | Containers prepared |
| Phase 2 | ✅ Complete | Backups created |
| Phase 3 | ⚠️ **PAUSED** | **Stopped before removing tools** |
| Phase 4 | ⏳ Pending | GUI apps migration |
| Phase 5 | ⏳ Pending | System cleanup |
| Phase 6 | ⏳ Pending | Verification |

**Current state**: Safe! All tools available both in container AND on system.

---

## Should We Continue Migration?

### Option A: Continue Migration (Recommended)
```bash
# You have TWO ways to access tools:
# 1. System: btop, vim, tree (current)
# 2. Container: docker exec dev <tool>

# After removal, you'll use:
docker exec -it dev bash  # enter container shell
# Then use tools normally
```

### Option B: Keep Both (Safe, but wastes space)
```bash
# Keep system tools installed
# Also use container when needed
# Wastes ~50 MB for duplicates
```

### Option C: Fix Distrobox Integration
```bash
# Recreate container with distrobox
# Then use: distrobox enter dev
# More seamless integration
```

---

## Quick Test - Verify Container Works

```bash
# 1. Check container is running
docker ps | grep dev

# 2. Test git in container
docker exec dev git --version

# 3. Test node in container
docker exec dev node --version

# 4. Enter container and use tools
docker exec -it dev bash
# Now you're inside - try: git, node, vim, htop
exit
```

---

## Recommendation

**Use Option 2 (Enter Container Shell)**:

1. When you need development tools:
   ```bash
   docker exec -it dev bash
   cd ~/my-project
   git status
   node app.js
   vim file.js
   ```

2. For system monitoring (quick access):
   ```bash
   docker exec dev htop
   docker exec dev btop  # if it was in container
   ```

3. Add this to `~/.zshrc` for convenience:
   ```bash
   alias dev='docker exec -it dev bash'
   ```

Then just type: `dev` to enter your development environment!

---

## Next Steps

**Choose one**:

1. ✅ **Continue migration** - Remove system tools, use container (clean system)
2. ⏸️ **Pause migration** - Keep both for now (test container more)
3. 🔧 **Fix distrobox** - Recreate container with distrobox (better integration)

**Current recommendation**: Use the container for a few days, then continue migration when comfortable.

---

## Remember

- ✅ **Container has all tools** (working right now!)
- ✅ **System still has tools** (nothing removed yet!)
- ✅ **Backups created** (can rollback anytime)
- ✅ **Safe to test** (no risk)

**You have TWO copies of tools right now - System AND Container!**
