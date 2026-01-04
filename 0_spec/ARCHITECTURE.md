# Kinoite Bifrost

> **A RAM-optimized dual-profile security OS based on Fedora Kinoite**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│    ██╗  ██╗██╗███╗   ██╗ ██████╗ ██╗████████╗███████╗                      │
│    ██║ ██╔╝██║████╗  ██║██╔═══██╗██║╚══██╔══╝██╔════╝                      │
│    █████╔╝ ██║██╔██╗ ██║██║   ██║██║   ██║   █████╗                        │
│    ██╔═██╗ ██║██║╚██╗██║██║   ██║██║   ██║   ██╔══╝                        │
│    ██║  ██╗██║██║ ╚████║╚██████╔╝██║   ██║   ███████╗                      │
│    ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝   ╚═╝   ╚══════╝                      │
│                                                                             │
│    ██████╗ ██╗███████╗██████╗  ██████╗ ███████╗████████╗                   │
│    ██╔══██╗██║██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝                   │
│    ██████╔╝██║█████╗  ██████╔╝██║   ██║███████╗   ██║                      │
│    ██╔══██╗██║██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║                      │
│    ██████╔╝██║██║     ██║  ██║╚██████╔╝███████║   ██║                      │
│    ╚═════╝ ╚═╝╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝                      │
│                                                                             │
│                    ANON ══════════════════ AUTH                             │
│                           (the bridge)                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> **Device**: Surface Pro 8 (8GB RAM, 256GB NVMe)
> **Base**: Fedora Kinoite 41 (Immutable, atomic updates)
> **Goal**: QubesOS-style profile isolation with full RAM per session

---

## What is Kinoite Bifrost?

**Bifrost** is a custom Fedora Kinoite distribution that provides **QubesOS-level profile isolation** without the RAM overhead of running separate kernel instances.

### The Problem with QubesOS on 8GB RAM

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     QUBES OS RAM USAGE (8GB total)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────┐  dom0 (admin VM)           ~1.5 GB                   │
│   ├─────────────────┤  sys-net (network)         ~400 MB                   │
│   ├─────────────────┤  sys-firewall              ~400 MB                   │
│   ├─────────────────┤  ANON qube                 ~2.0 GB                   │
│   ├─────────────────┤  AUTH qube                 ~2.0 GB                   │
│   ├─────────────────┤  Overhead (Xen, buffers)   ~1.5 GB                   │
│   └─────────────────┘                            ────────                   │
│                                                   ~7.8 GB                   │
│                                                                             │
│   RAM per profile: ~2 GB (unusable for real work!)                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### The Bifrost Solution

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   KINOITE BIFROST RAM USAGE (8GB total)                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                                                                     │  │
│   │                    ANON   or   AUTH                                 │  │
│   │                                                                     │  │
│   │                      FULL 8 GB RAM                                  │  │
│   │                                                                     │  │
│   │                   (one profile at a time)                           │  │
│   │                                                                     │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   RAM per profile: 8 GB (full system resources!)                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Isolation Spectrum: Where Bifrost Sits

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ISOLATION vs RAM TRADE-OFF                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  SECURITY ─────────────────────────────────────────────────────────────►   │
│  WEAKER                                                          STRONGER   │
│                                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│  │  User    │  │Namespace │  │ BIFROST  │  │ QubesOS  │  │ Air Gap  │     │
│  │ Accounts │  │ (Podman) │  │(BTRFS+   │  │ (Xen VMs)│  │ (2 PCs)  │     │
│  │          │  │          │  │  LUKS)   │  │          │  │          │     │
│  ├──────────┤  ├──────────┤  ├──────────┤  ├──────────┤  ├──────────┤     │
│  │ Same /etc│  │ Shared   │  │ Separate │  │ Separate │  │ Separate │     │
│  │ Same /var│  │ kernel   │  │ /etc,/var│  │ kernels  │  │ hardware │     │
│  │ Shared   │  │ Shared   │  │ Shared   │  │ Split    │  │ Full     │     │
│  │ RAM      │  │ RAM      │  │ kernel   │  │ RAM      │  │ RAM each │     │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  └──────────┘     │
│                                   ▲                                        │
│                                   │                                        │
│                              YOU ARE HERE                                  │
│                                                                             │
│  RAM per      8 GB          8 GB          8 GB          ~2 GB       8 GB   │
│  profile:   (shared)      (shared)      (shared)      (split)    (each PC) │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### The Fundamental Trade-off

| Approach | Kernel Isolation | Full RAM per Profile | Concurrent Profiles |
|----------|------------------|----------------------|---------------------|
| **Bifrost** | No (shared) | **Yes (8 GB)** | No (one at a time) |
| **QubesOS** | Yes (Xen) | No (~2 GB each) | Yes |
| **Dual-boot (2 OS)** | Yes | **Yes (8 GB)** | No |
| **16GB+ RAM** | Yes (Xen) | Yes (~8 GB each) | Yes |

### Key Insight

> **Shared kernel is the ONLY way to get full RAM per profile on limited hardware.**

Without kernel isolation (Xen, KVM), profiles share:
- The same Linux kernel in memory (~200 MB, not duplicated)
- The same system libraries in RAM (shared via CoW)
- **Result: Full 8 GB available to whichever profile is active**

With kernel isolation (QubesOS, Kata):
- Each VM loads its own kernel (~200 MB × N)
- Each VM has dedicated RAM allocation
- Xen hypervisor overhead (~500 MB+)
- **Result: RAM split between VMs, each gets ~2-3 GB**

---

## What Bifrost Provides

| Feature | Method | Benefit |
|---------|--------|---------|
| **Profile isolation** | BTRFS subvolumes | Separate filesystems per profile |
| **Config separation** | @etc-anon, @etc-auth | Different hostname, SSH keys, network |
| **State separation** | @var-anon, @var-auth | Different logs, containers, cache |
| **Crypto hiding** | Nested LUKS | AUTH data invisible to ANON |
| **Full RAM** | Shared kernel | 8 GB per active profile |
| **Atomic updates** | rpm-ostree | Immutable /usr, rollback support |
| **Container isolation** | Podman rootless | Additional app-level isolation |

### Bifrost = QubesOS Model - Kernel Overhead

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   QubesOS isolation model                                                   │
│           +                                                                 │
│   Single-kernel efficiency (like standard Linux)                           │
│           +                                                                 │
│   Only 2 profiles (not N qubes)                                            │
│           =                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                                                                     │  │
│   │               KINOITE BIFROST                                       │  │
│   │                                                                     │  │
│   │       QubesOS-style isolation optimized for 8 GB RAM                │  │
│   │                                                                     │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Comparison: Bifrost vs Alternatives

| Aspect | Bifrost | QubesOS | Dual-boot | Podman-only |
|--------|---------|---------|-----------|-------------|
| RAM per profile | **8 GB** | ~2 GB | **8 GB** | 8 GB (shared) |
| Install effort | 4 scripts | 1 ISO | Install twice | Minimal |
| Maintenance | Custom | Automatic | 2× updates | Minimal |
| /etc isolation | **Yes** | Yes | Yes | No |
| /var isolation | **Yes** | Yes | Yes | No |
| Kernel isolation | No | **Yes** | Yes | No |
| Profile switching | Reboot | Window switch | Reboot | - |
| Surface Pro support | **Custom kernel** | Limited | Manual | N/A |
| Immutable OS | **Yes (ostree)** | Yes (templates) | No | No |

---

## When to Use What

| Your Situation | Recommendation |
|----------------|----------------|
| 8 GB RAM, need full resources per profile | **Bifrost** |
| 16 GB+ RAM, need concurrent profiles | QubesOS |
| Simple isolation, no special requirements | Dual-boot |
| Just want container isolation | Podman + Firejail |
| Maximum paranoia, budget available | 2 separate devices |

---

## Target Hardware

| Component | Specification | Notes |
|-----------|--------------|-------|
| Device | Surface Pro 8 | linux-surface kernel required |
| RAM | 8 GB | Optimized for limited RAM |
| Storage | 256 GB NVMe | LUKS + BTRFS subvolumes |
| Secure Boot | **Disabled** | Required for linux-surface |

---

## Surface Pro 8 Linux Support

### linux-surface Repository

Surface Pro 8 requires the **linux-surface** kernel and drivers for full hardware support.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SURFACE PRO 8 HARDWARE SUPPORT                            │
├──────────────────────┬──────────────────┬───────────────────────────────────┤
│      Component       │     Status       │            Notes                  │
├──────────────────────┼──────────────────┼───────────────────────────────────┤
│ Touchscreen          │ ✓ Works          │ linux-surface kernel              │
│ Pen/Stylus           │ ✓ Works          │ iptsd daemon required             │
│ Type Cover Keyboard  │ ✓ Works          │ linux-surface kernel              │
│ Type Cover Trackpad  │ ✓ Works          │ libwacom for gestures             │
│ WiFi (Intel AX201)   │ ✓ Works          │ Stock kernel OK                   │
│ Bluetooth            │ ✓ Works          │ Stock kernel OK                   │
│ Audio (speakers)     │ ✓ Works          │ linux-surface kernel              │
│ Cameras (front/rear) │ ✗ Limited        │ IPU6 driver issues - use Windows  │
│ Windows Hello IR     │ ✗ No support     │ Use Windows for facial auth       │
│ Battery              │ ✓ Works          │ surface_aggregator module         │
│ Power button         │ ✓ Works          │ linux-surface kernel              │
│ Hibernate            │ ⚠ Partial        │ May need kernel params            │
│ Secure Boot          │ ✗ Disabled       │ Required for linux-surface        │
└──────────────────────┴──────────────────┴───────────────────────────────────┘
```

### Installation (Fedora Kinoite)

```bash
# ═══════════════════════════════════════════════════════════════════════════
# Add linux-surface repository
# ═══════════════════════════════════════════════════════════════════════════
sudo wget -O /etc/yum.repos.d/linux-surface.repo \
  https://pkg.surfacelinux.com/fedora/linux-surface.repo

# Import signing key
sudo rpm --import https://pkg.surfacelinux.com/keys/surface.asc

# ═══════════════════════════════════════════════════════════════════════════
# Install Surface kernel and tools
# ═══════════════════════════════════════════════════════════════════════════
rpm-ostree install \
  kernel-surface \
  kernel-surface-devel \
  iptsd \
  libwacom-surface \
  surface-control

# Reboot to new kernel
systemctl reboot

# ═══════════════════════════════════════════════════════════════════════════
# Enable touchscreen/pen daemon
# ═══════════════════════════════════════════════════════════════════════════
sudo systemctl enable --now iptsd
```

### Installation (Arch Linux - @light)

```bash
# ═══════════════════════════════════════════════════════════════════════════
# Add linux-surface repository to pacman.conf
# ═══════════════════════════════════════════════════════════════════════════
cat >> /etc/pacman.conf << 'EOF'

[linux-surface]
Server = https://pkg.surfacelinux.com/arch/
EOF

# Import signing key
curl -s https://pkg.surfacelinux.com/keys/surface.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 56C464BAAC421453

# ═══════════════════════════════════════════════════════════════════════════
# Install Surface packages
# ═══════════════════════════════════════════════════════════════════════════
sudo pacman -Syu
sudo pacman -S linux-surface linux-surface-headers iptsd surface-control

# Update bootloader
sudo mkinitcpio -P
sudo grub-mkconfig -o /boot/grub/grub.cfg  # or update rEFInd

# Enable services
sudo systemctl enable --now iptsd

# Reboot
reboot
```

### Kernel Parameters (rEFInd)

```bash
# /boot/efi/EFI/refind/refind.conf - add to boot options:
options "root=/dev/mapper/cryptouter rootflags=subvol=@kde \
  quiet splash \
  mem_sleep_default=deep \
  nvme.noacpi=1 \
  i915.enable_psr=0"
```

### Webcam Workaround

Since IPU6 cameras don't work reliably on Linux:
- **Mode A:** Boot into Windows for video calls
- **Mode B:** Use Windows VM with USB passthrough (from KDE host)
- **Alternative:** USB webcam (works immediately)

---

## User & Authentication Configuration

### Authentication Model: Single Password + Auto-Login

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SINGLE PASSWORD AUTHENTICATION                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ANON Profile:                                                              │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐                │
│  │ Enter ANON   │  →  │  OUTER LUKS  │  →  │  Auto-login  │                │
│  │ LUKS password│     │   unlocked   │     │  as 'anon'   │                │
│  └──────────────┘     └──────────────┘     └──────────────┘                │
│                                                                             │
│  AUTH Profile:                                                              │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐                │
│  │ Enter AUTH   │  →  │ OUTER+INNER  │  →  │  Auto-login  │                │
│  │ LUKS password│     │   unlocked   │     │  as 'diego'  │                │
│  └──────────────┘     └──────────────┘     └──────────────┘                │
│                                                                             │
│  ONE PASSWORD = Full access (LUKS is the security layer)                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Users

| User | Password | UID | Host sudo | Podman/Container | Auto-login | Profile |
|------|----------|-----|-----------|------------------|------------|---------|
| `anon` | `1234567890` | 1000 | **NO** | ✓ Root inside containers | ✓ After ANON LUKS | ANON |
| `diego` | `1234567890` | 1000 | **NOPASSWD** | ✓ Root inside containers | ✓ After AUTH LUKS | AUTH |

```bash
# ANON user - NO host sudo, but can run rootless containers
useradd -m -u 1000 -s /bin/bash anon
echo "anon:1234567890" | chpasswd
usermod -aG podman anon  # Can run containers (rootless)
# NOT in wheel group - cannot sudo on host

# AUTH user (diego) - full sudo + containers
useradd -m -u 1000 -G wheel -s /bin/bash diego
echo "diego:1234567890" | chpasswd
usermod -aG podman diego
echo "diego ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/diego
chmod 440 /etc/sudoers.d/diego
```

### Podman Rootless Setup

```bash
# Enable rootless podman for anon (can be root INSIDE containers)
loginctl enable-linger anon
loginctl enable-linger diego

# Verify anon can run containers
su - anon
podman run --rm -it alpine sh
# Inside container: whoami → root
# On host: anon still can't sudo
```

### Configure Auto-Login

**KDE (SDDM):**
```bash
# /etc/sddm.conf.d/autologin.conf
[Autologin]
User=diego          # or 'anon' for ANON profile
Session=plasma.desktop
```

**Light (LightDM/getty):**
```bash
# /etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin diego --noclear %I $TERM
# or 'anon' for ANON profile
```

### Permission Model

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PERMISSION COMPARISON                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  anon (ANON Profile):                                                       │
│  ├── Host system: REGULAR USER (no sudo)                                    │
│  ├── Cannot: install packages, modify system, access /etc                   │
│  ├── Can: run podman containers                                             │
│  └── Inside container: ROOT (full control inside container only)            │
│                                                                             │
│  diego (AUTH Profile):                                                      │
│  ├── Host system: FULL SUDO (NOPASSWD)                                      │
│  ├── Can: everything on host                                                │
│  ├── Can: run podman containers                                             │
│  └── Inside container: ROOT                                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Security Model:**
- LUKS password = THE security (protects all data)
- User password = Not needed (auto-login)
- anon: No host sudo, but root inside containers (isolated)
- diego: Full sudo + containers (trusted after AUTH LUKS)

### SSH Configuration

```bash
# /etc/ssh/sshd_config
PubkeyAuthentication yes
PubkeyAcceptedKeyTypes ssh-rsa,rsa-sha2-256,rsa-sha2-512
PasswordAuthentication yes          # TODO: Disable after setup complete
PermitEmptyPasswords no
PermitRootLogin no
MaxAuthTries 5

# No 2FA required for SSH
```

**TODO:** After setup is stable, disable SSH password:
```bash
# Change to: PasswordAuthentication no
# Then: systemctl restart sshd
```

### Human Login 2FA Options (OPTIONAL)

2FA is **NOT enabled by default**. Users can optionally configure one of these methods:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         2FA OPTIONS FOR LOGIN                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Option A: TOTP (Aegis App)                                                 │
│  ─────────────────────────                                                  │
│  Time-based one-time passwords via Aegis app on phone                       │
│  Install: rpm-ostree install google-authenticator                           │
│  Setup: google-authenticator (scan QR with Aegis)                           │
│  PAM: auth required pam_google_authenticator.so nullok                      │
│                                                                             │
│  Option B: Passkey (Bitwarden)                                              │
│  ────────────────────────────                                               │
│  WebAuthn passkey stored in Bitwarden                                       │
│  Install: rpm-ostree install libfido2 pam-u2f                               │
│  Setup: pamu2fcfg > ~/.config/Yubico/u2f_keys                               │
│  PAM: auth sufficient pam_u2f.so cue                                        │
│                                                                             │
│  Option C: FIDO2 Key (YubiKey / Phone)                                      │
│  ─────────────────────────────────────                                      │
│  Hardware security key or phone as FIDO2 authenticator                      │
│  Install: rpm-ostree install pam-u2f                                        │
│  Setup: pamu2fcfg > ~/.config/Yubico/u2f_keys                               │
│  PAM: auth sufficient pam_u2f.so cue [cue_prompt=Touch key]                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Authentication Matrix

| Context | anon | diego | Method |
|---------|------|-------|--------|
| LUKS unlock | ANON password | AUTH password | Single password entry |
| GUI/Console | **Auto-login** | **Auto-login** | No password needed |
| SSH | RSA key (password fallback) | RSA key (password fallback) | No 2FA |
| Host sudo | **BLOCKED** | **NOPASSWD** | anon cannot modify host |
| Podman containers | ✓ Root inside | ✓ Root inside | Rootless containers |
| Screen lock | Optional | Optional | 2FA optional |

**Notes:**
- LUKS password is THE security layer
- Auto-login after LUKS unlock (no second password)
- anon: No host sudo, but can run containers with root inside
- diego: Full host sudo + containers

---

## Security Model

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            OUTSIDE WORLD                                         │
│                          (sees encrypted data)                                   │
│                                                                                  │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                                                                          │   │
│   │   Password "anon"                         Password "auth"               │   │
│   │        │                                        │                        │   │
│   │        ▼                                        ▼                        │   │
│   │   Opens OUTER                             Opens OUTER                    │   │
│   │   LUKS only                               + INNER LUKS                   │   │
│   │        │                                        │                        │   │
│   │        ▼                                        ▼                        │   │
│   │   ┌───────────────┐                   ┌─────────────────────────┐       │   │
│   │   │ ANON Profile  │                   │ ANON + AUTH Profiles    │       │   │
│   │   │ Tor, Privacy  │                   │ Full access to all      │       │   │
│   │   │ Burner IDs    │                   │ Personal + Anonymous    │       │   │
│   │   └───────────────┘                   └─────────────────────────┘       │   │
│   │                                                                          │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Access Matrix:**

| Password | Outer LUKS | Inner LUKS | Sees ANON | Sees AUTH |
|----------|------------|------------|-----------|-----------|
| ANON | ✓ Unlocks | ✗ Locked | ✓ | ✗ |
| AUTH | ✓ Unlocks | ✓ Unlocks | ✓ | ✓ |

---

## Environments

### Available Modes (2 boots + Windows, session selection at SDDM)

| Boot Entry | LUKS Password | Auto-login User | Session Options |
|------------|---------------|-----------------|-----------------|
| Kinoite ANON | ANON | anon | KDE, Openbox, Android, Tor Kiosk |
| Kinoite AUTH | AUTH | diego | KDE, Openbox, Android, Chrome Kiosk |
| Windows | - | - | Windows (Camera/Firmware) |

### Session Matrix

| Session | ANON | AUTH | Purpose |
|---------|------|------|---------|
| **KDE Plasma** | ✓ | ✓ | Full desktop environment |
| **Openbox** | ✓ | ✓ | Lightweight, focused work |
| **Android (Waydroid)** | ✓ | ✓ | Mobile apps, touch mode |
| **Tor Kiosk** | ✓ | ✗ | Anonymous browsing (ANON only) |
| **Chrome Kiosk** | ✗ | ✓ | Google services (AUTH only) |

**Single OS = KDE + Openbox + Waydroid + Kiosk modes (~12 GB)**
**All dev tools run in Podman containers**
**Session selection happens at SDDM login screen (or via session switcher)**

---

## Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              rEFInd Boot Manager                                        │
│                        (Surface UEFI - Secure Boot OFF)                                │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│  ┌────────┬────────────────────────────────────────────────────────────────┬──────┐   │
│  │  EFI   │                     OUTER LUKS (~200 GB)                       │Win11 │   │
│  │ 500MB  │                (Password: ANON or AUTH)                        │20 GB │   │
│  │        │                                                                │      │   │
│  │        │  ┌────────────────────── BTRFS Pool ─────────────────────────┐ │      │   │
│  │        │  │                                                            │ │      │   │
│  │        │  │  ┌──────────── Single OS Root (immutable /usr) ─────────┐ │ │      │   │
│  │        │  │  │  @root (~12GB) - Kinoite + KDE + Openbox + Waydroid   │ │ │      │   │
│  │        │  │  └───────────────────────────────────────────────────────┘ │ │      │   │
│  │        │  │                                                            │ │      │   │
│  │        │  │  ┌──────────── ANON Profile (mutable state) ─────────────┐ │ │      │   │
│  │        │  │  │  @etc-anon     │  @var-anon     │ System configs/state │ │ │      │   │
│  │        │  │  │  @tools-anon   │  @vault-anon   │  @shared-anon        │ │ │      │   │
│  │        │  │  │  Tor, Privacy  │  Burner IDs    │  Anon-only files     │ │ │      │   │
│  │        │  │  └────────────────────────────────────────────────────────┘ │ │      │   │
│  │        │  │                                                            │ │      │   │
│  │        │  │  ┌──────────── Shared Data (both profiles) ───────────────┐│ │      │   │
│  │        │  │  │  @shared-common (~25GB) - Downloads, Media, Transfer   ││ │      │   │
│  │        │  │  └────────────────────────────────────────────────────────┘│ │      │   │
│  │        │  │                                                            │ │      │   │
│  │        │  │  ┌──────────── INNER LUKS (auth.luks ~55GB) ──────────────┐│ │      │   │
│  │        │  │  │            (Only AUTH password unlocks)                 ││ │      │   │
│  │        │  │  │  ┌─────────── AUTH Profile (private) ────────────────┐ ││ │      │   │
│  │        │  │  │  │  @etc-auth     │  @var-auth     │ Hidden configs!  │ ││ │      │   │
│  │        │  │  │  │  @tools-auth   │  @vault-auth   │  @shared-auth    │ ││ │      │   │
│  │        │  │  │  │  Claude, Git   │  SSH/GPG/API   │  Docs, Projects  │ ││ │      │   │
│  │        │  │  │  └────────────────────────────────────────────────────┘ ││ │      │   │
│  │        │  │  └─────────────────────────────────────────────────────────┘│ │      │   │
│  │        │  │                                                            │ │      │   │
│  │        │  │  @snapshots (dynamic) - BTRFS snapshots for rollback       │ │      │   │
│  │        │  │                                                            │ │      │   │
│  │        │  └────────────────────────────────────────────────────────────┘ │      │   │
│  └────────┴────────────────────────────────────────────────────────────────┴──────┘   │
│                                                                                         │
│                          + swapfile inside LUKS (16 GB)                                 │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Disk Layout (256GB NVMe)

| Partition | Size | Filesystem | Content |
|-----------|------|------------|---------|
| nvme0n1p1 | 500 MB | FAT32 | EFI System |
| nvme0n1p2 | ~215 GB | LUKS + BTRFS | Encrypted Pool (includes swap) |
| nvme0n1p3 | 20 GB | NTFS | Windows (Camera) |

**Total: ~236 GB**

**Note:** Swap is a file inside LUKS pool (`/mnt/pool/swapfile`) for security - no unencrypted swap partition.

### BTRFS Subvolumes (Outer LUKS)

| Subvolume | Size | Access | Purpose |
|-----------|------|--------|---------|
| @root | ~12 GB | Both | Single OS: Kinoite + KDE + Openbox + Waydroid (immutable /usr) |
| @etc-anon | ~200 MB | ANON | ANON's /etc (system configs, hostname, network) |
| @var-anon | ~3 GB | ANON | ANON's /var (logs, containers state, cache) |
| @shared-common | ~25 GB | Both | **Shared data** (Downloads, Media, Transfer) |
| @tools-anon | ~5 GB | ANON | Tor, DNSCrypt, Privacy containers |
| @vault-anon | ~1 GB | ANON | Burner SSH keys, disposable IDs |
| @shared-anon | ~10 GB | ANON | ANON-only private files |
| @snapshots | dynamic | Both | BTRFS snapshots for rollback |
| auth.luks | ~55 GB | AUTH only | Inner encrypted container |

### BTRFS Subvolumes (Inner LUKS - auth.luks)

| Subvolume | Size | Access | Purpose |
|-----------|------|--------|---------|
| @etc-auth | ~200 MB | AUTH only | AUTH's /etc (hidden from ANON!) |
| @var-auth | ~3 GB | AUTH only | AUTH's /var (hidden from ANON!) |
| @tools-auth | ~10 GB | AUTH only | Claude, Git, Dev containers |
| @vault-auth | ~1 GB | AUTH only | SSH, GPG, API keys |
| @shared-auth | ~35 GB | AUTH only | Documents, Projects |

### Why /etc and /var Are Separated

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    COMPLETE PROFILE ISOLATION                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   @etc contains (profile-specific):          @var contains:             │
│   ├── /etc/hostname                          ├── /var/log/              │
│   ├── /etc/NetworkManager/                   ├── /var/lib/containers/   │
│   ├── /etc/ssh/ssh_host_*                    ├── /var/lib/flatpak/      │
│   ├── /etc/sddm.conf.d/                      ├── /var/cache/            │
│   └── /etc/systemd/                          └── /var/tmp/              │
│                                                                          │
│   ANON boots → mounts @etc-anon, @var-anon                              │
│   AUTH boots → mounts @etc-auth, @var-auth (from inner LUKS!)           │
│                                                                          │
│   Result: ZERO cross-contamination, ZERO config leakage                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Data Access Summary

| Data Location | ANON sees | AUTH sees | Purpose |
|---------------|-----------|-----------|---------|
| ~/shared/ | ✓ | ✓ | Common downloads, media, transfer zone |
| ~/private/ | ✓ (own) | ✓ (own) | Profile-specific private files |
| ~/vault/ | ✓ (anon) | ✓ (diego) | Secrets (never cross-accessible) |
| /mnt/anon/ | - | ✓ (optional) | AUTH can browse ANON files |

---

## Boot Menu

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            rEFInd Boot Manager                                   │
│                                                                                  │
│         🔒 Kinoite ANON          🔐 Kinoite AUTH          🪟 Windows            │
│         (ANON password)          (AUTH password)          (Camera)              │
│                                                                                  │
│              Use arrows to select, Enter to boot                                 │
└─────────────────────────────────────────────────────────────────────────────────┘

After LUKS unlock → SDDM session selection:

┌─────────────────────────────────┐    ┌─────────────────────────────────┐
│      ANON Boot → SDDM           │    │       AUTH Boot → SDDM          │
│                                 │    │                                 │
│  Session: [▼ KDE Plasma    ]    │    │  Session: [▼ KDE Plasma    ]    │
│           ┌────────────────┐    │    │           ┌────────────────┐    │
│           │ KDE Plasma     │    │    │           │ KDE Plasma     │    │
│           │ Openbox        │    │    │           │ Openbox        │    │
│           │ Android        │    │    │           │ Android        │    │
│           │ Tor Kiosk      │    │    │           │ Chrome Kiosk   │    │
│           └────────────────┘    │    │           └────────────────┘    │
│                                 │    │                                 │
│  User: anon (auto-login)        │    │  User: diego (auto-login)       │
└─────────────────────────────────┘    └─────────────────────────────────┘
```

---

## Boot Flow

### ANON Boot

```
1. Select "Kinoite ANON" in rEFInd
2. Prompt: "Enter LUKS password"
3. Enter ANON password → Unlocks OUTER LUKS only
4. Mounts from OUTER LUKS:
   - @root → /           (shared OS, immutable /usr)
   - @etc-anon → /etc    (ANON's system config)
   - @var-anon → /var    (ANON's logs, containers, cache)
   - @tools-anon, @vault-anon, @shared-anon, @shared-common
5. Inner LUKS (auth.luks) remains LOCKED - AUTH data INVISIBLE
6. SDDM starts → Session switcher OR auto-login
7. Choose: KDE Plasma | Openbox | Android | Tor Kiosk
8. Desktop loads with ANON profile
```

### AUTH Boot

```
1. Select "Kinoite AUTH" in rEFInd
2. Prompt: "Enter LUKS password"
3. Enter AUTH password → Unlocks OUTER LUKS
4. Keyfile inside unlocks INNER LUKS automatically
5. Mounts from INNER LUKS (hidden from ANON!):
   - @etc-auth → /etc    (AUTH's system config)
   - @var-auth → /var    (AUTH's logs, containers, cache)
   - @tools-auth, @vault-auth, @shared-auth
6. Mounts from OUTER LUKS:
   - @root → /           (shared OS, immutable /usr)
   - @shared-common
   - Optionally @*-anon → /mnt/anon/ for full access
7. SDDM starts → Session switcher OR auto-login
8. Choose: KDE Plasma | Openbox | Android | Chrome Kiosk
9. Desktop loads with AUTH profile (full access to both)
```

### Session Selection with Auto-Login

**Problem:** Auto-login skips SDDM, so no session choice.

**Solution:** Session Switcher script runs after auto-login:

```bash
# /usr/local/bin/session-switcher.sh
# Shows graphical session picker on first login, remembers choice

#!/bin/bash
LAST_SESSION="$HOME/.config/last-session"

if [[ ! -f "$LAST_SESSION" ]] || [[ "$1" == "--choose" ]]; then
    # Show session picker (zenity/kdialog)
    SESSION=$(zenity --list --title="Choose Session" \
        --column="Session" "plasma" "openbox" "android" "kiosk")
    echo "$SESSION" > "$LAST_SESSION"
fi

# Switch to chosen session if different from current
# (logout and re-login with selected session)
```

**Alternative:** Disable auto-login, use SDDM session dropdown (requires entering password twice: LUKS + SDDM)

---

## Containerized Tooling

Each OS is **minimal** (GUI + terminal + file manager only). All tools run in **Podman containers**.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Minimal Host OS (~5-10 GB)                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                         │
│  │   Desktop   │  │  Terminal   │  │    File     │                         │
│  │ Environment │  │  (Konsole)  │  │   Manager   │                         │
│  │  (KDE/OB)   │  │             │  │  (Dolphin)  │                         │
│  └─────────────┘  └─────────────┘  └─────────────┘                         │
│                              │                                              │
│                              ▼                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    Podman Container (~2-10 GB)                        │  │
│  │                                                                       │  │
│  │  ANON Container:              AUTH Container:                        │  │
│  │  ┌─────────┐ ┌─────────┐     ┌─────────┐ ┌─────────┐ ┌─────────┐   │  │
│  │  │   Tor   │ │DNSCrypt │     │ Claude  │ │  Git    │ │ Python  │   │  │
│  │  │         │ │  Proxy  │     │  Code   │ │         │ │ Node.js │   │  │
│  │  └─────────┘ └─────────┘     └─────────┘ └─────────┘ └─────────┘   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Container Profiles

| Profile | Container | Tools | Use Case |
|---------|-----------|-------|----------|
| **ANON** | cloud-connect:anon | Tor, DNSCrypt, Privacy tools | Anonymous browsing |
| **AUTH** | cloud-connect:auth | Claude, Git, Python, Node, Rust | Development |

---

## Vault Structure

### @vault-anon (Burner identities)

```
@vault-anon/
├── tor/              ← Tor configs
├── burner-keys/      ← Disposable SSH keys
├── temp-gpg/         ← Temporary GPG keys
└── anon-configs/     ← Anonymous service configs
```

### @vault-auth (Personal identity)

```
@vault-auth/
├── ssh/              ← Personal SSH keys
│   ├── id_rsa
│   └── known_hosts
├── gpg/              ← Personal GPG keys
├── api/              ← API tokens
│   ├── anthropic.key
│   ├── google.key
│   └── github.key
├── cloud/            ← Cloud CLI configs
│   ├── oci/
│   └── gcloud/
└── bitwarden/        ← Password manager backup
```

---

## LUKS Setup Commands

```bash
# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: Create partitions
# ═══════════════════════════════════════════════════════════════════════════

# p1: EFI (500MB), p2: LUKS (~215GB), p3: Windows (20GB)
# Swap is a file inside LUKS, not a partition

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: Setup OUTER LUKS with two key slots
# ═══════════════════════════════════════════════════════════════════════════

# Create LUKS container (first password = ANON)
cryptsetup luksFormat /dev/nvme0n1p2
# Enter ANON password

# Add second key slot (AUTH password)
cryptsetup luksAddKey /dev/nvme0n1p2
# Enter existing (ANON) password, then new (AUTH) password

# Open outer LUKS
cryptsetup open /dev/nvme0n1p2 cryptouter

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3: Create BTRFS and subvolumes in OUTER
# ═══════════════════════════════════════════════════════════════════════════

mkfs.btrfs -L pool /dev/mapper/cryptouter
mount /dev/mapper/cryptouter /mnt

# Single OS root (KDE + Openbox + Waydroid) - /usr is immutable via ostree
btrfs subvolume create /mnt/@root

# ANON profile - mutable system state (hidden from AUTH only by choice)
btrfs subvolume create /mnt/@etc-anon      # ANON's /etc (hostname, network, ssh host keys)
btrfs subvolume create /mnt/@var-anon      # ANON's /var (logs, containers, cache)
btrfs subvolume create /mnt/@tools-anon    # ANON containers
btrfs subvolume create /mnt/@vault-anon    # ANON secrets
btrfs subvolume create /mnt/@shared-anon   # ANON private files

# Shared data (accessible by both profiles)
btrfs subvolume create /mnt/@shared-common

# Snapshots
btrfs subvolume create /mnt/@snapshots

# Create swap file inside LUKS
dd if=/dev/zero of=/mnt/swapfile bs=1G count=16 status=progress
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: Create INNER LUKS container for AUTH
# ═══════════════════════════════════════════════════════════════════════════

# Create container file (~60GB)
dd if=/dev/zero of=/mnt/auth.luks bs=1M count=60000 status=progress

# Format as LUKS (use keyfile derived from AUTH password)
cryptsetup luksFormat /mnt/auth.luks

# Create keyfile that only AUTH password can access
# (Store encrypted in outer LUKS, decrypted by initramfs based on password)
dd if=/dev/urandom of=/mnt/.auth-keyfile bs=4096 count=1
chmod 000 /mnt/.auth-keyfile
cryptsetup luksAddKey /mnt/auth.luks /mnt/.auth-keyfile

# Open inner LUKS
cryptsetup open /mnt/auth.luks cryptinner --key-file /mnt/.auth-keyfile

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5: Create BTRFS and subvolumes in INNER
# ═══════════════════════════════════════════════════════════════════════════

mkfs.btrfs -L auth /dev/mapper/cryptinner
mount /dev/mapper/cryptinner /mnt/auth

# AUTH profile - mutable system state (HIDDEN from ANON - inside inner LUKS!)
btrfs subvolume create /mnt/auth/@etc-auth      # AUTH's /etc (reveals identity!)
btrfs subvolume create /mnt/auth/@var-auth      # AUTH's /var (activity history!)
btrfs subvolume create /mnt/auth/@tools-auth    # AUTH containers
btrfs subvolume create /mnt/auth/@vault-auth    # AUTH secrets
btrfs subvolume create /mnt/auth/@shared-auth   # AUTH private files

umount /mnt/auth
umount /mnt
```

---

## SDDM Session Setup

### Install Desktop Environments

```bash
# On Fedora Kinoite (rpm-ostree)
rpm-ostree install \
    openbox obconf tint2 nitrogen feh \
    cage \
    chromium \
    zenity

# Reboot to apply
systemctl reboot
```

### Create Custom Session Files

```bash
# ═══════════════════════════════════════════════════════════════════════════
# Android Session (Waydroid fullscreen)
# ═══════════════════════════════════════════════════════════════════════════
cat > /usr/share/wayland-sessions/android.desktop << 'EOF'
[Desktop Entry]
Name=Android (Waydroid)
Comment=Full Android UI via Waydroid
Exec=cage -- waydroid show-full-ui
Type=Application
DesktopNames=Android
EOF

# ═══════════════════════════════════════════════════════════════════════════
# Tor Kiosk Session (ANON only)
# ═══════════════════════════════════════════════════════════════════════════
cat > /usr/share/wayland-sessions/tor-kiosk.desktop << 'EOF'
[Desktop Entry]
Name=Tor Kiosk
Comment=Anonymous browsing with Tor Browser
Exec=cage -- torbrowser-launcher
Type=Application
DesktopNames=TorKiosk
EOF

# ═══════════════════════════════════════════════════════════════════════════
# Chrome Kiosk Session (AUTH only)
# ═══════════════════════════════════════════════════════════════════════════
cat > /usr/share/wayland-sessions/chrome-kiosk.desktop << 'EOF'
[Desktop Entry]
Name=Chrome Kiosk
Comment=Google Chrome in kiosk mode
Exec=cage -- chromium --kiosk --start-fullscreen
Type=Application
DesktopNames=ChromeKiosk
EOF
```

### Profile-Specific Session Filtering

```bash
# ═══════════════════════════════════════════════════════════════════════════
# Boot script to enable/disable sessions based on profile
# /usr/local/bin/configure-sessions.sh (runs at boot via systemd)
# ═══════════════════════════════════════════════════════════════════════════
#!/bin/bash

SESSIONS_DIR="/usr/share/wayland-sessions"

# Detect profile based on mounted subvolumes
if mountpoint -q /home/diego/vault 2>/dev/null; then
    PROFILE="auth"
else
    PROFILE="anon"
fi

# Enable/disable sessions based on profile
if [[ "$PROFILE" == "anon" ]]; then
    # ANON: Enable Tor, disable Chrome
    chmod 644 "$SESSIONS_DIR/tor-kiosk.desktop"
    chmod 000 "$SESSIONS_DIR/chrome-kiosk.desktop"
    # Set auto-login user
    sed -i 's/^User=.*/User=anon/' /etc/sddm.conf.d/autologin.conf
else
    # AUTH: Enable Chrome, disable Tor
    chmod 000 "$SESSIONS_DIR/tor-kiosk.desktop"
    chmod 644 "$SESSIONS_DIR/chrome-kiosk.desktop"
    # Set auto-login user
    sed -i 's/^User=.*/User=diego/' /etc/sddm.conf.d/autologin.conf
fi
```

### Session Switcher (for auto-login)

```bash
# ═══════════════════════════════════════════════════════════════════════════
# /usr/local/bin/session-switcher.sh
# Shows session picker after auto-login, allows switching without logout
# ═══════════════════════════════════════════════════════════════════════════
#!/bin/bash

LAST_SESSION="$HOME/.config/last-session"
CURRENT_SESSION="${XDG_CURRENT_DESKTOP:-plasma}"

# Get available sessions based on profile
if [[ "$USER" == "anon" ]]; then
    SESSIONS="KDE Plasma|Openbox|Android|Tor Kiosk"
else
    SESSIONS="KDE Plasma|Openbox|Android|Chrome Kiosk"
fi

# Show picker if no saved session or --choose flag
if [[ ! -f "$LAST_SESSION" ]] || [[ "$1" == "--choose" ]]; then
    CHOICE=$(zenity --list --title="Choose Session" \
        --text="Select your desktop environment:" \
        --column="Session" \
        $(echo "$SESSIONS" | tr '|' '\n'))

    if [[ -n "$CHOICE" ]]; then
        echo "$CHOICE" > "$LAST_SESSION"

        # Map choice to session file
        case "$CHOICE" in
            "KDE Plasma") SESSION="plasma" ;;
            "Openbox") SESSION="openbox" ;;
            "Android") SESSION="android" ;;
            "Tor Kiosk") SESSION="tor-kiosk" ;;
            "Chrome Kiosk") SESSION="chrome-kiosk" ;;
        esac

        # If different from current, logout and switch
        if [[ "$SESSION" != "$CURRENT_SESSION" ]]; then
            # Update SDDM config and logout
            echo "Session=$SESSION.desktop" >> ~/.config/sddm-session
            loginctl terminate-user "$USER"
        fi
    fi
fi
```

### Auto-Start Session Switcher

```bash
# ~/.config/autostart/session-switcher.desktop
[Desktop Entry]
Name=Session Switcher
Exec=/usr/local/bin/session-switcher.sh
Type=Application
X-GNOME-Autostart-enabled=true
```

---

## Mount Configuration

### ANON Boot fstab

```bash
# OS root (single OS for all sessions) - /usr is immutable via ostree
/dev/mapper/cryptouter  /                      btrfs  subvol=@root,noatime  0 0

# ANON's mutable system state (CRITICAL for profile isolation!)
/dev/mapper/cryptouter  /etc                   btrfs  subvol=@etc-anon,noatime  0 0
/dev/mapper/cryptouter  /var                   btrfs  subvol=@var-anon,noatime  0 0

# Shared data (accessible by both profiles)
/dev/mapper/cryptouter  /home/anon/shared      btrfs  subvol=@shared-common  0 0

# ANON profile data
/dev/mapper/cryptouter  /home/anon/tools       btrfs  subvol=@tools-anon  0 0
/dev/mapper/cryptouter  /home/anon/vault       btrfs  subvol=@vault-anon  0 0
/dev/mapper/cryptouter  /home/anon/private     btrfs  subvol=@shared-anon 0 0

# AUTH profile - NOT MOUNTED (inner LUKS locked)

# Volatile tmpfs for sensitive temp data
tmpfs  /tmp      tmpfs  defaults,noatime,mode=1777,size=2G  0 0
```

### AUTH Boot fstab

```bash
# OS root (single OS for all sessions) - /usr is immutable via ostree
/dev/mapper/cryptouter  /                       btrfs  subvol=@root,noatime  0 0

# AUTH's mutable system state (from INNER LUKS - hidden from ANON!)
/dev/mapper/cryptinner  /etc                    btrfs  subvol=@etc-auth,noatime  0 0
/dev/mapper/cryptinner  /var                    btrfs  subvol=@var-auth,noatime  0 0

# Shared data (accessible by both profiles)
/dev/mapper/cryptouter  /home/diego/shared      btrfs  subvol=@shared-common  0 0

# AUTH profile data (from inner LUKS)
/dev/mapper/cryptinner  /home/diego/tools       btrfs  subvol=@tools-auth  0 0
/dev/mapper/cryptinner  /home/diego/vault       btrfs  subvol=@vault-auth  0 0
/dev/mapper/cryptinner  /home/diego/private     btrfs  subvol=@shared-auth 0 0

# Optional: mount ANON data for full access (AUTH can see everything)
/dev/mapper/cryptouter  /mnt/anon/private       btrfs  subvol=@shared-anon  0 0
/dev/mapper/cryptouter  /mnt/anon/vault         btrfs  subvol=@vault-anon   0 0
/dev/mapper/cryptouter  /mnt/anon/etc           btrfs  subvol=@etc-anon     0 0
/dev/mapper/cryptouter  /mnt/anon/var           btrfs  subvol=@var-anon     0 0

# Volatile tmpfs for sensitive temp data
tmpfs  /tmp      tmpfs  defaults,noatime,mode=1777,size=2G  0 0
```

### Home Directory Structure

```
/home/anon/                         /home/diego/
├── shared/    → @shared-common     ├── shared/    → @shared-common
│   ├── Downloads/                  │   ├── Downloads/
│   ├── Music/                      │   ├── Music/
│   ├── Videos/                     │   ├── Videos/
│   └── Transfer/                   │   └── Transfer/
│                                   │
├── tools/     → @tools-anon        ├── tools/     → @tools-auth
│   └── (containers, scripts)       │   └── (containers, dev tools)
│                                   │
├── private/   → @shared-anon       ├── private/   → @shared-auth
│   └── (anon-only files)           │   ├── Documents/
│                                   │   └── Projects/
│                                   │
└── vault/     → @vault-anon        └── vault/     → @vault-auth
    └── burner-keys/                    ├── ssh/
                                        ├── gpg/
                                        └── api/

System Directories (mounted per profile):

ANON boots:                         AUTH boots:
/etc  → @etc-anon                   /etc  → @etc-auth (from inner LUKS!)
/var  → @var-anon                   /var  → @var-auth (from inner LUKS!)
```

---

## Waydroid (Android Container)

Waydroid runs inside KDE/Light, stores data in @android subvolume:

```bash
# Install on Kinoite
rpm-ostree install waydroid
systemctl reboot

# Initialize with Google Apps
sudo waydroid init -s GAPPS

# Launch full Android UI
waydroid show-full-ui
```

**ANON Android:** Uses @tools-anon, @vault-anon
**AUTH Android:** Uses @tools-auth, @vault-auth

---

## Quick Reference

| Task | Boot | Session | Password |
|------|------|---------|----------|
| Anonymous browsing | Kinoite ANON | Tor Kiosk | ANON |
| Lightweight anon work | Kinoite ANON | Openbox | ANON |
| Full anon desktop | Kinoite ANON | KDE Plasma | ANON |
| Development work | Kinoite AUTH | KDE Plasma | AUTH |
| Lightweight dev work | Kinoite AUTH | Openbox | AUTH |
| Google services | Kinoite AUTH | Chrome Kiosk | AUTH |
| Android apps (anon) | Kinoite ANON | Android | ANON |
| Android apps (personal) | Kinoite AUTH | Android | AUTH |
| Video call (webcam) | Windows | - | None |
| Firmware updates | Windows | - | None |

---

## Security Summary

| Layer | Protection | Method |
|-------|------------|--------|
| External (theft) | All data encrypted | LUKS |
| ANON profile | Separate identity | Own vault/tools |
| AUTH profile | Personal data hidden | Nested LUKS |
| Between boots | Complete separation | Different mounts |

---

## Hybrid Access Modes

The architecture supports **two access modes**: direct multi-boot for maximum performance, or VM mode from KDE for convenience.

### Mode A: Multi-Boot (via rEFInd)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        BARE METAL BOOT                                   │
│                   (Full hardware access, max performance)                │
│                                                                         │
│   rEFInd → Select OS → LUKS unlock → Boot directly on hardware          │
│                                                                         │
│   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌─────────┐              │
│   │  KDE   │ │  KDE   │ │ Light  │ │ Light  │ │ Windows │              │
│   │  Anon  │ │  Auth  │ │  Anon  │ │  Auth  │ │         │              │
│   └────────┘ └────────┘ └────────┘ └────────┘ └─────────┘              │
└─────────────────────────────────────────────────────────────────────────┘
```

**Use when:**
- Maximum performance needed (gaming, video editing)
- Full hardware access (all 8GB RAM)
- Battery optimization
- Clean profile isolation (no host traces)

---

### Mode B: VM Mode (from KDE Host)

KDE serves as host OS, launching other environments as VMs via **Kata Containers** (for Linux) and **QEMU/KVM** (for Windows).

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     KDE AUTH as Host                                     │
│               (Inner LUKS unlocked - full access)                        │
│                                                                         │
│   ┌───────────────────────────────────────────────────────────────────┐ │
│   │                    KDE Kinoite Auth (HOST)                         │ │
│   │                        ~3-4 GB RAM                                 │ │
│   │                                                                    │ │
│   │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │ │
│   │   │  Kata VM:    │  │  Kata VM:    │  │  QEMU/KVM:   │           │ │
│   │   │ Light Anon   │  │ Light Auth   │  │   Windows    │           │ │
│   │   │   ~1 GB      │  │   ~1 GB      │  │   ~2-3 GB    │           │ │
│   │   └──────────────┘  └──────────────┘  └──────────────┘           │ │
│   │                                                                    │ │
│   │   ┌──────────────┐  ┌──────────────┐                              │ │
│   │   │  Waydroid:   │  │   Podman:    │  (shares kernel,             │ │
│   │   │   Android    │  │    Tools     │   minimal overhead)          │ │
│   │   └──────────────┘  └──────────────┘                              │ │
│   │                                                                    │ │
│   └───────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                     KDE ANON as Host                                     │
│                (Inner LUKS locked - ANON access only)                    │
│                                                                         │
│   ┌───────────────────────────────────────────────────────────────────┐ │
│   │                    KDE Kinoite Anon (HOST)                         │ │
│   │                        ~3-4 GB RAM                                 │ │
│   │                                                                    │ │
│   │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │ │
│   │   │  Kata VM:    │  │  QEMU/KVM:   │  │   Podman:    │           │ │
│   │   │ Light Anon   │  │   Windows    │  │  Anon Tools  │           │ │
│   │   │   ~1 GB      │  │   ~2-3 GB    │  │              │           │ │
│   │   └──────────────┘  └──────────────┘  └──────────────┘           │ │
│   │                                                                    │ │
│   │   ┌──────────────┐                                                │ │
│   │   │  Waydroid:   │   ✗ Light Auth (BLOCKED - no access)          │ │
│   │   │ Android Anon │   ✗ AUTH tools (BLOCKED - no access)          │ │
│   │   └──────────────┘   ✗ @vault-auth (BLOCKED - inner LUKS locked) │ │
│   │                                                                    │ │
│   └───────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

**Use when:**
- Need multiple environments simultaneously
- Quick switching without reboot
- Testing/development across profiles
- Convenience over raw performance

---

### Mode B Access Matrix

| Host | Can Launch | Cannot Launch |
|------|------------|---------------|
| **KDE Auth** | Light Anon, Light Auth, Windows VM, Waydroid, All Podman containers | - |
| **KDE Anon** | Light Anon, Windows VM, Waydroid Anon, Anon Podman containers | Light Auth, AUTH tools, @vault-auth |

---

## Isolation Levels

```
┌───────────────────────────────────────────────────────────────────────────┐
│                        ISOLATION COMPARISON                               │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  STRONGEST ──────────────────────────────────────────────────► WEAKEST   │
│                                                                           │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐  │
│  │ Multi-Boot  │   │  Kata VM    │   │  QEMU/KVM   │   │   Podman    │  │
│  │             │   │             │   │             │   │  Container  │  │
│  ├─────────────┤   ├─────────────┤   ├─────────────┤   ├─────────────┤  │
│  │ Separate    │   │ Micro-VM    │   │ Full VM     │   │ Namespace   │  │
│  │ boot, no    │   │ per         │   │ emulation   │   │ isolation   │  │
│  │ host kernel │   │ container   │   │             │   │ only        │  │
│  │             │   │             │   │             │   │             │  │
│  │ 100% RAM    │   │ ~1GB each   │   │ ~2-3GB each │   │ Shared RAM  │  │
│  │             │   │             │   │             │   │             │  │
│  │ Zero        │   │ Hardware    │   │ Hardware    │   │ Kernel      │  │
│  │ shared      │   │ virt        │   │ virt        │   │ shared      │  │
│  │ state       │   │ (VT-x)      │   │ (VT-x)      │   │             │  │
│  └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘  │
│                                                                           │
│  Use: Max       Use: Linux       Use: Windows      Use: Dev tools,       │
│  security,      envs from        from KDE,         Tor, DNSCrypt         │
│  performance    KDE host         webcam access                           │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## Kata Containers Setup (KDE Host)

```bash
# ═══════════════════════════════════════════════════════════════════════════
# Install Kata on Fedora Kinoite
# ═══════════════════════════════════════════════════════════════════════════

rpm-ostree install kata-containers
systemctl reboot

# Configure podman to use kata runtime
mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf << 'EOF'
[engine]
runtime = "kata"
EOF

# ═══════════════════════════════════════════════════════════════════════════
# Create Light Anon VM definition
# ═══════════════════════════════════════════════════════════════════════════

# Option 1: Run @light subvolume as Kata VM
podman run --runtime=kata \
  -v /mnt/pool/@light:/rootfs:ro \
  -v /mnt/pool/@tools-anon:/var/lib/containers \
  -v /mnt/pool/@vault-anon:/home/user/vault \
  --memory=1g \
  light-anon:latest

# Option 2: Use pre-built Light image
podman run --runtime=kata \
  --name light-anon-vm \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  --memory=1g \
  archlinux-openbox:anon
```

---

## QEMU/KVM Windows VM (KDE Host)

```bash
# ═══════════════════════════════════════════════════════════════════════════
# Install QEMU/KVM on Fedora Kinoite
# ═══════════════════════════════════════════════════════════════════════════

rpm-ostree install qemu-kvm libvirt virt-manager
systemctl reboot

# Enable libvirt
sudo systemctl enable --now libvirtd

# ═══════════════════════════════════════════════════════════════════════════
# Create Windows VM with USB passthrough for webcam
# ═══════════════════════════════════════════════════════════════════════════

virt-install \
  --name windows-camera \
  --ram 3072 \
  --vcpus 2 \
  --disk /mnt/pool/windows.qcow2,size=20 \
  --cdrom /path/to/win11.iso \
  --os-variant win11 \
  --graphics spice \
  --video qxl \
  --hostdev 001.003  # USB webcam passthrough
```

**Webcam in VM:**
- Pass USB device to VM: `--hostdev <bus>.<device>`
- Find webcam: `lsusb | grep -i camera`
- Full webcam access without rebooting to Windows

---

## VM Storage Access (virtio-fs)

VMs access BTRFS subvolumes via **virtio-fs** for near-native performance:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          KDE Host                                        │
│                                                                         │
│   BTRFS Pool (/mnt/pool)                                                │
│   ├── @tools-anon  ──────┬──── virtio-fs ────►  Light Anon VM           │
│   ├── @vault-anon  ──────┤                      /home/user/vault        │
│   ├── @shared-anon ──────┘                      /shared                 │
│   │                                                                     │
│   ├── @tools-auth  ──────┬──── virtio-fs ────►  Light Auth VM           │
│   ├── @vault-auth  ──────┤                      /home/user/vault        │
│   └── @shared-auth ──────┘                      /shared                 │
└─────────────────────────────────────────────────────────────────────────┘
```

```bash
# virtiofsd for shared folders
/usr/libexec/virtiofsd \
  --socket-path=/tmp/vhost-fs.sock \
  --shared-dir=/mnt/pool/@shared-anon \
  --cache=always

# In VM XML config
<filesystem type="mount">
  <driver type="virtiofs"/>
  <source socket="/tmp/vhost-fs.sock"/>
  <target dir="shared"/>
</filesystem>
```

---

## Memory Allocation (8GB Constraint)

| Mode | Host | VM 1 | VM 2 | Available |
|------|------|------|------|-----------|
| Multi-boot | 8 GB | - | - | Full RAM |
| KDE + Podman | 4 GB | - | - | 4 GB for containers |
| KDE + 1 Kata VM | 4 GB | 1 GB | - | 3 GB buffer |
| KDE + Windows VM | 3.5 GB | 3 GB | - | 1.5 GB buffer |
| KDE + Light + Win | 3 GB | 1 GB | 2.5 GB | Tight! |

**Recommendation:** Run max 1 VM at a time with 8GB RAM. Use multi-boot for heavy workloads.

---

## Use Case Decision Matrix

| Scenario | Recommended Mode | Why |
|----------|------------------|-----|
| Anonymous browsing (Tor) | Multi-boot → Light Anon | Clean slate, no host traces |
| Quick webcam call | KDE Auth → Windows VM | No reboot, USB passthrough |
| Heavy development | Multi-boot → KDE Auth | Full 8GB RAM |
| Testing anon config | KDE Auth → Light Anon VM | Quick iteration |
| Paranoid mode | Multi-boot → Light Anon | Maximum isolation |
| Simultaneous profiles | KDE Auth → Light Anon VM | Access both |
| Gaming/Video editing | Multi-boot → Windows | Full GPU, RAM |

---

## Security Considerations

### Network Isolation

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      NETWORK CONFIGURATION                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ANON Profile:                       AUTH Profile:                      │
│  ┌─────────────────────────┐        ┌─────────────────────────┐        │
│  │ DNS: DNSCrypt/Cloudflare│        │ DNS: System default      │        │
│  │ Traffic: Tor/VPN        │        │ Traffic: Direct          │        │
│  │ MAC: Randomized         │        │ MAC: Hardware            │        │
│  │ Hostname: randomized    │        │ Hostname: surface-diego  │        │
│  └─────────────────────────┘        └─────────────────────────┘        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**ANON Network Setup:**
```bash
# MAC randomization (NetworkManager)
nmcli connection modify "WiFi" wifi.cloned-mac-address random
nmcli connection modify "WiFi" ethernet.cloned-mac-address random

# Force DNS through DNSCrypt
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf  # Prevent changes

# Random hostname on boot
hostnamectl set-hostname "$(openssl rand -hex 4)"
```

---

### Swap Encryption

**CRITICAL:** Swap must be encrypted to prevent RAM data leakage.

```bash
# Option 1: Swap inside LUKS (recommended)
# Create swap file inside encrypted pool
dd if=/dev/zero of=/mnt/pool/swapfile bs=1G count=16
chmod 600 /mnt/pool/swapfile
mkswap /mnt/pool/swapfile

# Option 2: Encrypted swap partition with random key (ephemeral)
# /etc/crypttab:
cryptswap /dev/nvme0n1p4 /dev/urandom swap,cipher=aes-xts-plain64,size=256

# /etc/fstab:
/dev/mapper/cryptswap none swap sw 0 0
```

**Chosen approach:** Swap inside LUKS pool (shares encryption with data).

---

### Hibernate/Suspend Security

| State | Risk | Mitigation |
|-------|------|------------|
| **Suspend (S3)** | RAM preserved, LUKS keys in memory | Lock screen, require password |
| **Hibernate (S4)** | RAM written to swap | Encrypted swap required |
| **Cold boot attack** | RAM can be frozen and read | Disable suspend, use shutdown |

**Recommendations:**
```bash
# Disable suspend for paranoid mode
systemctl mask suspend.target hibernate.target

# Or require LUKS password on resume
# /etc/systemd/system/luks-resume.service
```

---

### Cross-Profile Contamination Risks

| Risk | Vector | Mitigation | Status |
|------|--------|------------|--------|
| **Shared OS root** | /usr binaries | Immutable via ostree + separate /etc, /var | ✓ SOLVED |
| **Config leakage** | /etc files reveal identity | Separate @etc-anon, @etc-auth subvolumes | ✓ SOLVED |
| **Log leakage** | /var/log activity history | Separate @var-anon, @var-auth subvolumes | ✓ SOLVED |
| **Container state** | /var/lib/containers | Each profile has own @var subvolume | ✓ SOLVED |
| **Browser state** | Cookies, history | Separate browser profiles + tmpfs | ✓ SOLVED |
| **Clipboard (VM)** | Copy between host/VM | Disable clipboard sharing | Manual |
| **BTRFS metadata** | File access times | noatime mount option | ✓ SOLVED |

**Complete Isolation Summary:**
```
┌─────────────────────────────────────────────────────────────────────────┐
│                    FINAL ISOLATION MODEL                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Shared (intentionally):                                                │
│  └── @root /usr   → Immutable via ostree (cannot be modified at runtime)│
│  └── @shared-common → Explicit shared data (Downloads, Media)           │
│                                                                          │
│  Isolated per profile:                                                  │
│  ├── /etc         → @etc-anon OR @etc-auth (configs, hostname, ssh keys)│
│  ├── /var         → @var-anon OR @var-auth (logs, containers, cache)    │
│  ├── /home/*/     → Separate home directories                           │
│  └── /tmp         → tmpfs (volatile, never persisted)                   │
│                                                                          │
│  AUTH's @etc-auth and @var-auth are in INNER LUKS:                      │
│  └── ANON cannot see AUTH's configs, logs, or container state!          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**Mitigations Applied:**
```bash
# Separate /etc and /var per profile (in fstab)
/dev/mapper/cryptouter  /etc  btrfs  subvol=@etc-anon,noatime  0 0  # ANON
/dev/mapper/cryptinner  /etc  btrfs  subvol=@etc-auth,noatime  0 0  # AUTH (inner LUKS!)

# Mount options (noatime prevents access time leakage)
mount -o noatime,subvol=@root /dev/mapper/cryptouter /

# tmpfs for temp files (never persisted to disk)
tmpfs /tmp tmpfs defaults,noatime,mode=1777,size=2G 0 0
```

---

### Deniability Considerations

**Current design:** Inner LUKS (`auth.luks`) is visible as a file.

```
Can AUTH existence be hidden?
├── auth.luks file → VISIBLE in outer LUKS
├── File size (~80GB) → Clearly not random data
└── ANON user can see file exists → NOT DENIABLE
```

**Plausible deniability options (NOT implemented):**

| Method | Complexity | Deniability |
|--------|------------|-------------|
| Hidden LUKS header | Medium | Moderate |
| VeraCrypt hidden volume | High | Strong |
| Decoy + hidden OS | Very High | Strongest |

**Current stance:** Deniability not a goal. Focus on:
- Protection from theft (both profiles encrypted)
- Protection of AUTH from ANON access (nested LUKS)
- NOT protection from forensic analysis

---

### Secure Deletion on BTRFS

**Problem:** BTRFS copy-on-write (CoW) means old data may persist.

```bash
# Standard delete does NOT securely erase
rm secret.txt  # Old blocks still on disk!

# Workarounds:
# 1. Encrypt at file level (GPG)
gpg -c secret.txt && rm secret.txt

# 2. Use nodatacow for sensitive files
chattr +C /vault/sensitive/
# Must be set on empty file/dir before writing

# 3. Full subvolume delete + TRIM
btrfs subvolume delete @vault-anon
fstrim -v /mnt/pool

# 4. Re-create LUKS container (nuclear option)
# Regenerate auth.luks with new key
```

**Recommendation:** Sensitive files in vault should use file-level encryption (GPG).

---

### Emergency Scenarios

#### Panic Wipe (Duress)

```bash
# Script: /usr/local/bin/panic-wipe.sh
#!/bin/bash
# WARNING: DESTROYS ALL DATA

# Wipe LUKS headers (makes data irrecoverable)
cryptsetup luksErase /dev/nvme0n1p2 --batch-mode

# Or just wipe first 10MB (faster, destroys header)
dd if=/dev/urandom of=/dev/nvme0n1p2 bs=1M count=10

# Trigger kernel panic to force shutdown
echo c > /proc/sysrq-trigger
```

**Trigger options:**
- Keyboard shortcut (dangerous - accidental trigger)
- Specific boot option in rEFInd
- USB dead man's switch

#### Forgotten Password Recovery

| Scenario | Recovery |
|----------|----------|
| Forgot ANON password | Use AUTH password (unlocks outer) |
| Forgot AUTH password | ANON still works, AUTH data **LOST** |
| Forgot both | All data **LOST** - restore from backup |

**Backup strategy required** (see below).

---

### Backup Strategy

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         BACKUP ARCHITECTURE                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  On-device (BTRFS snapshots):                                           │
│  ├── @snapshots/daily/     ← Automatic daily snapshots                  │
│  ├── @snapshots/weekly/    ← Weekly retention                           │
│  └── @snapshots/manual/    ← Before major changes                       │
│                                                                         │
│  Off-device (encrypted):                                                │
│  ├── External SSD          ← LUKS-encrypted backup drive                │
│  ├── Cloud (rclone)        ← Encrypted before upload                    │
│  └── Cold storage          ← Paper key backup for LUKS headers          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Snapshot automation:**
```bash
# /etc/systemd/system/btrfs-snapshot.timer
[Timer]
OnCalendar=daily
Persistent=true

# /etc/systemd/system/btrfs-snapshot.service
[Service]
ExecStart=/usr/local/bin/btrfs-snapshot.sh
```

**Off-device backup:**
```bash
# Backup to encrypted external drive
btrfs send /mnt/pool/@snapshots/latest | \
  gpg -c --cipher-algo AES256 | \
  dd of=/dev/sdb1

# Backup LUKS header (CRITICAL - store safely)
cryptsetup luksHeaderBackup /dev/nvme0n1p2 \
  --header-backup-file luks-header-outer.bin
cryptsetup luksHeaderBackup /mnt/pool/auth.luks \
  --header-backup-file luks-header-inner.bin
# Encrypt and store headers separately from data!
```

---

### Browser Profile Isolation

| Browser | ANON Config | AUTH Config |
|---------|-------------|-------------|
| Firefox | Separate profile, Tor mode | Default profile |
| Chromium | Guest mode or container | Normal |

```bash
# Firefox profiles
firefox -P anon  # Hardened, no history
firefox -P auth  # Normal browsing

# Or use Flatpak sandboxing
flatpak run --filesystem=~/.mozilla-anon org.mozilla.firefox
```

---

### Firmware Updates

**Surface Pro requires Windows for firmware updates.**

Options:
1. Boot into Windows partition periodically
2. Use Windows VM (may not work for firmware)
3. Accept risk of outdated firmware

**Recommendation:** Boot Windows monthly for updates.

---

## Threat Model Summary

| Threat | Protected | Method |
|--------|-----------|--------|
| Device theft | ✓ | Full disk LUKS encryption |
| Border crossing / coercion | Partial | Nested LUKS (AUTH hidden from ANON) |
| Forensic analysis | ✗ | Inner LUKS visible, not deniable |
| Remote compromise | Partial | Profile isolation, minimal attack surface |
| Physical access (cold boot) | Partial | Encrypted swap, shutdown vs suspend |
| Network surveillance | ✓ (ANON) | Tor, DNSCrypt, MAC randomization |
| Cross-profile leakage | Partial | Separate mounts, volatile logs |

---

## Future Upgrades

- **32GB RAM**: Run multiple VMs simultaneously
- **512GB NVMe**: Larger partitions, more snapshots
- **External GPU**: Passthrough for gaming/ML
- **YubiKey**: Hardware 2FA for AUTH unlock
- **Looking Glass**: Zero-latency Windows VM display
- **VeraCrypt hidden volume**: True deniability if needed
- **Heads/Skulls firmware**: Tamper-evident boot
