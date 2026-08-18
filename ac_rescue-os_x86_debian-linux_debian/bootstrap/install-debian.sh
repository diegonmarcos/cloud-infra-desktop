#!/bin/bash
# Debian Rescue OS - Bootstrap Install Script
# Run from Kali (or any running Linux with debootstrap + internet) to install
# Debian trixie onto /dev/nvme0n1p6 with rEFInd integration (no GRUB).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET="${TARGET:-/dev/nvme0n1p6}"
MOUNT="${MOUNT:-/mnt/p6}"
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
HOSTNAME_NEW="${HOSTNAME_NEW:-rescue-os-debian}"
ESP="${ESP:-/mnt/efi}"
KERNEL_DIR="$ESP/EFI/debian"
REFIND_CONF="$ESP/EFI/refind/refind.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error()   { printf "${RED}[x]${NC} %s\n" "$1"; exit 1; }
section() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }

# ────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ────────────────────────────────────────────────────────────────────────────

[ "$(id -u)" != "0" ] && error "Run as root: sudo $0"
[ ! -b "$TARGET" ] && error "Target partition $TARGET not found"
[ ! -d "$ESP" ] && error "ESP not mounted at $ESP — mount it first: sudo mount /dev/nvme0n1p1 $ESP"
[ ! -f "$SCRIPT_DIR/chroot-setup.sh" ] && error "chroot-setup.sh missing"
[ ! -f "$SCRIPT_DIR/apt-sources.list" ] && error "apt-sources.list missing"

# Refuse if target is mounted somewhere
if findmnt -nr "$TARGET" >/dev/null 2>&1; then
    error "$TARGET is currently mounted — unmount first"
fi

# ────────────────────────────────────────────────────────────────────────────
# Confirm
# ────────────────────────────────────────────────────────────────────────────

cat <<EOF

============================================================
  Debian Rescue OS — Bootstrap Install
============================================================

  Target:    $TARGET
  Mount:     $MOUNT
  Suite:     $SUITE
  Mirror:    $MIRROR
  Hostname:  $HOSTNAME_NEW
  ESP:       $ESP (kernel → $KERNEL_DIR)
  rEFInd:    $REFIND_CONF (will append menuentry)

  This will ERASE $TARGET and any data on it!

EOF
read -p "  Continue? [y/N] " confirm
[ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && exit 0

# ────────────────────────────────────────────────────────────────────────────
# Host prep
# ────────────────────────────────────────────────────────────────────────────

if ! command -v debootstrap >/dev/null 2>&1; then
    section "Installing debootstrap on host"
    apt-get update -qq
    apt-get install -y debootstrap
fi

# ────────────────────────────────────────────────────────────────────────────
# Format + mount
# ────────────────────────────────────────────────────────────────────────────

section "Formatting $TARGET as ext4 (label=rescue-os-debian)"
mkfs.ext4 -F -L "rescue-os-debian" "$TARGET"

section "Mounting $TARGET → $MOUNT"
mkdir -p "$MOUNT"
mount "$TARGET" "$MOUNT"

# ────────────────────────────────────────────────────────────────────────────
# debootstrap
# ────────────────────────────────────────────────────────────────────────────

section "Running debootstrap $SUITE (2-5 minutes)"
debootstrap --arch=amd64 --variant=minbase \
    --include=ca-certificates,gnupg,curl,locales,tzdata,sudo,systemd-sysv,apt-utils \
    "$SUITE" "$MOUNT" "$MIRROR"

# ────────────────────────────────────────────────────────────────────────────
# In-chroot prep
# ────────────────────────────────────────────────────────────────────────────

section "Copying apt sources, resolv.conf, chroot-setup.sh"
cp "$SCRIPT_DIR/apt-sources.list" "$MOUNT/etc/apt/sources.list"
cp /etc/resolv.conf "$MOUNT/etc/resolv.conf"
cp "$SCRIPT_DIR/chroot-setup.sh" "$MOUNT/root/chroot-setup.sh"
chmod +x "$MOUNT/root/chroot-setup.sh"

section "Bind-mounting kernel filesystems into chroot"
mount -t proc proc "$MOUNT/proc"
mount --rbind /sys "$MOUNT/sys"; mount --make-rslave "$MOUNT/sys"
mount --rbind /dev "$MOUNT/dev"; mount --make-rslave "$MOUNT/dev"

# Cleanup trap
cleanup() {
    section "Cleanup"
    umount -R "$MOUNT/dev"  2>/dev/null || umount -l "$MOUNT/dev"  2>/dev/null || true
    umount -R "$MOUNT/sys"  2>/dev/null || umount -l "$MOUNT/sys"  2>/dev/null || true
    umount       "$MOUNT/proc" 2>/dev/null || true
    umount       "$MOUNT"      2>/dev/null || true
}
trap cleanup EXIT

# ────────────────────────────────────────────────────────────────────────────
# Run chroot setup
# ────────────────────────────────────────────────────────────────────────────

section "Entering chroot to run setup"
chroot "$MOUNT" /bin/bash /root/chroot-setup.sh

# ────────────────────────────────────────────────────────────────────────────
# fstab + crypttab
# ────────────────────────────────────────────────────────────────────────────

section "Generating /etc/fstab"
ROOT_UUID=$(blkid -s UUID -o value "$TARGET")
ESP_UUID=$(blkid -s UUID -o value /dev/nvme0n1p1)
cat > "$MOUNT/etc/fstab" <<EOF
# /etc/fstab - Debian Rescue OS (rescue-os-debian)
#
# <device>                                                          <mount>       <fs>     <opts>                              <dump> <pass>
UUID=$ROOT_UUID  /             ext4     defaults,noatime                       0      1
UUID=$ESP_UUID                                                                 /mnt/efi      vfat     defaults,noauto,uid=1000,gid=1000      0      0
UUID=0eaf7961-48c5-4b55-8a8f-04cd0b71de07                           /mnt/boot     ext4     defaults,noauto                        0      0
UUID=7e3626ac-ce13-4adc-84e2-1a843d7e2793                           /mnt/shared-lib ext4   defaults,noauto                        0      0
UUID=509491e4-d3a7-426d-9b78-4b024b24cc32                           /mnt/kali     ext4     defaults,noauto                        0      0
/dev/mapper/pool                                                    /mnt/pool     btrfs    defaults,noauto,compress=zstd          0      0
EOF
log "fstab written (root UUID=$ROOT_UUID)"

section "Writing /etc/crypttab (LUKS pool, noauto)"
cat > "$MOUNT/etc/crypttab" <<'EOF'
# <name> <device>                                                   <keyfile> <options>
pool     UUID=3c75c6db-4d7c-4570-81f1-02d168781aac                  none      luks,noauto
EOF

# ────────────────────────────────────────────────────────────────────────────
# README to /home/diego (master tool docs)
# ────────────────────────────────────────────────────────────────────────────

if [ -f "$PARENT_DIR/TOOLS.md" ]; then
    section "Installing /home/diego/README.md from TOOLS.md"
    install -o 1000 -g 1000 -m 644 "$PARENT_DIR/TOOLS.md" "$MOUNT/home/diego/README.md"
fi

# Also drop a copy of the install dir contents at /home/diego/git/cloud-unix/... so
# user can re-run install.sh after first boot without needing the pool unlocked
if [ -d "$PARENT_DIR" ]; then
    section "Copying install scripts to /home/diego/git/cloud-unix/rescue-os-debian/"
    mkdir -p "$MOUNT/home/diego/git/cloud-unix/"
    cp -r "$PARENT_DIR" "$MOUNT/home/diego/git/cloud-unix/"
    chown -R 1000:1000 "$MOUNT/home/diego/git"
fi

# ────────────────────────────────────────────────────────────────────────────
# rEFInd menuentry
# ────────────────────────────────────────────────────────────────────────────
#
# We do NOT copy kernel+initrd to the ESP — the ESP on this machine is only
# 100 MB and Debian's initrd alone is ~50 MB, leaving no headroom for the
# other distros' kernels. Instead, rEFInd reads p6 directly via its ext4
# driver and points at the auto-updating symlinks /vmlinuz and /initrd.img
# at the root of the Debian filesystem (created by linux-image-amd64). This
# means apt kernel upgrades automatically pick up the new kernel — no manual
# ESP re-copy needed.

# Verify the symlinks exist before adding the menuentry
[ ! -e "$MOUNT/vmlinuz" ]    && error "/vmlinuz symlink missing on Debian root — kernel install incomplete"
[ ! -e "$MOUNT/initrd.img" ] && error "/initrd.img symlink missing on Debian root"
log "Debian kernel symlinks present: /vmlinuz → $(readlink "$MOUNT/vmlinuz")"

if [ -f "$REFIND_CONF" ]; then
    if grep -q "Debian Rescue OS" "$REFIND_CONF"; then
        log "rEFInd menuentry already present — skipping"
    else
        section "Adding rEFInd menuentry (volume debian, /vmlinuz, /initrd.img)"
        cat >> "$REFIND_CONF" <<EOF

menuentry "Debian Rescue OS" {
    icon     /EFI/refind/icons/os_debian.png
    volume   debian
    loader   /vmlinuz
    initrd   /initrd.img
    options  "root=UUID=$ROOT_UUID rw quiet"
}
EOF
        log "Menuentry added (volume=debian, root=UUID=$ROOT_UUID)"
    fi
else
    warn "rEFInd config not found at $REFIND_CONF — add a menuentry manually"
fi

# ────────────────────────────────────────────────────────────────────────────
# Log + done
# ────────────────────────────────────────────────────────────────────────────

LOGFILE="$PARENT_DIR/install_log.md"
echo "- $(date '+%Y-%m-%d %H:%M'): Debian $SUITE bootstrapped to $TARGET (root UUID=$ROOT_UUID)" >> "$LOGFILE"

cat <<EOF

============================================================
  Debian Rescue OS install complete
============================================================

  Reboot and select 'Debian Rescue OS' in rEFInd.

  First-boot login:
    user:  diego          / 1234567890
    root:  root           / 1234567890

  After first boot:
    cd ~/git/cloud-unix/rescue-os-debian
    ./install.sh scan      # verify packages
    ./install.sh install   # install anything missed (idempotent)
    ./install.sh browser   # one-shot Firefox via xinit (Claude OAuth)
    ./install.sh claude    # launch claude code

EOF
