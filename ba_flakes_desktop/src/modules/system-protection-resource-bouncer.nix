# System Protection — Resource Bouncer
# Memory: earlyoom, sysctl, cgroup caps, Docker MemoryMax
# SSH/WG OOM immunity, ext4 reserved blocks
# NOTE: zram is managed by NixOS host (configuration_system-protection.nix), not here
#
# Desktop equivalent: unix/aa_nixos-surface_host/src/modules/configuration_system-protection.nix
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ramMB, ... }:

let
  minFreeKB = if ramMB <= 1024 then 65536
              else if ramMB <= 8192 then 131072
              else 262144;

  dockerMaxMB = if ramMB <= 1024 then ramMB - 350
                else if ramMB <= 8192 then ramMB - 512
                else ramMB - 1024;

in {
  home.packages = [ pkgs.earlyoom pkgs.e2fsprogs ];

  # ── Sysctl ────────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/sysctl.conf".text = ''
    # Managed by home-manager (system-protection-resource-bouncer.nix)
    vm.min_free_kbytes = ${toString minFreeKB}
    vm.swappiness = 150
    vm.dirty_ratio = 10
    vm.dirty_background_ratio = 5
    vm.watermark_scale_factor = 500
    net.ipv4.ip_forward = 1
  '';

  # ── Earlyoom ──────────────────────────────────────────────────────────
  home.file.".local/share/system-protection/earlyoom.service".text = ''
    [Unit]
    Description=Early OOM Daemon (system-protection)
    After=multi-user.target
    [Service]
    Type=simple
    ExecStart=${pkgs.earlyoom}/bin/earlyoom \
      -m 10 -s 10 \
      --prefer "^(containerd-shim|nix-daemon|nix-build|nix)" \
      --avoid "^(sshd|ssh|systemd|earlyoom|dbus|wg-quick|wg)" \
      -r 0
    Restart=always
    RestartSec=2
    OOMScoreAdjust=-999
    MemoryMin=10M
    Nice=-20
    [Install]
    WantedBy=multi-user.target
  '';

  # SSH + WG + Docker slice assignments handled by system-protection-layer2-identity.nix

  # ── Docker memory cap ─────────────────────────────────────────────────
  home.file.".local/share/system-protection/docker-memory-cap.conf".text = ''
    [Service]
    MemoryMax=${toString dockerMaxMB}M
    MemoryHigh=${toString (dockerMaxMB * 9 / 10)}M
    OOMScoreAdjust=500
  '';

  # ── Activation ────────────────────────────────────────────────────────
  home.activation.installResourceBouncer = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    trap 'echo "[resource-bouncer] FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
    SUDO=""
    for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
      [ -x "$p" ] && SUDO="$p" && break
    done
    [ -z "$SUDO" ] && echo "[resource-bouncer] no sudo — skipping" && exit 0

    SRC="$HOME/.local/share/system-protection"

    # Sysctl
    $SUDO mkdir -p /etc/sysctl.d
    $SUDO cp -f "$SRC/sysctl.conf" /etc/sysctl.d/99-system-protection.conf
    $SUDO chmod 644 /etc/sysctl.d/99-system-protection.conf
    $SUDO sysctl --system > /dev/null 2>&1 || true

    # Ext4 reserved blocks
    ROOT_DEV=$($SUDO findmnt -n -o SOURCE / 2>/dev/null) || true
    ROOT_DEV=$(echo "$ROOT_DEV" | while read -r line; do echo "$line"; break; done)
    if [ -n "$ROOT_DEV" ] && $SUDO tune2fs -l "$ROOT_DEV" >/dev/null 2>&1; then
      $SUDO tune2fs -m 5 "$ROOT_DEV" 2>/dev/null || true
    fi

    # SSH/WG/Docker slice assignments handled by system-protection-layer2-identity.nix

    # Docker memory cap (separate from scheduler)
    if $SUDO systemctl cat "docker.service" >/dev/null 2>&1; then
      $SUDO mkdir -p "/etc/systemd/system/docker.service.d"
      $SUDO cp -f "$SRC/docker-memory-cap.conf" "/etc/systemd/system/docker.service.d/memory-cap.conf"
    fi

    # Earlyoom service
    $SUDO cp -f "$SRC/earlyoom.service" /etc/systemd/system/earlyoom.service

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable earlyoom.service 2>/dev/null || true
    $SUDO systemctl restart earlyoom.service 2>/dev/null || true

    echo "[resource-bouncer] deployed: mem=${toString (minFreeKB / 1024)}MB-reserve docker-cap=${toString dockerMaxMB}MB"
    ) || echo "[resource-bouncer] FAILED — activation continues"
  '';
}
