# Generic btrfs subvolume auto-creation — POST-INCIDENT 2026-05-16.
#
# WHY THIS EXISTS
# ───────────────
# On first nixos-install (or any boot where /mnt/btrfs-root wasn't mounted
# before activation), declarative btrfs subvol mounts SILENTLY fail because
# the subvolume on disk doesn't exist. Examples actually observed after the
# 2026-05-15 reinstall:
#
#   fileSystems."/var/log/journal" = { ... subvol=@shared/journal ... };
#   fileSystems."/var/lib/waydroid" = { ... subvol=@shared/waydroid-base ... };
#
# Both mounts had `nofail` — so boot continued, journald fell back to a
# tmpfs path that gets wiped on reboot (so there's NO PERSISTENT JOURNAL
# AVAILABLE TO DEBUG THE BOOT), waydroid lost its state.
#
# configuration_tmp.nix had the right pattern for /tmp's subvol specifically.
# This module generalises it: walk `config.fileSystems`, for every entry
# with `subvol=...` in its options, ensure that subvol exists on disk under
# /mnt/btrfs-root. Idempotent. Loud.
#
# WHY NOT FIX hardware_filesystems.nix
# ────────────────────────────────────
# fileSystems entries are DECLARATIVE MOUNT DECLARATIONS, not creation hooks.
# NixOS doesn't create the underlying storage — it expects you to. This
# module bridges that gap automatically for btrfs subvolumes.
{ config, lib, pkgs, ... }:

let
  # Extract "subvol=<name>" from a list of mount options.
  extractSubvol = options:
    let
      m = builtins.filter (s: builtins.match "subvol=.*" s != null) options;
    in if m == [] then null
       else lib.removePrefix "subvol=" (builtins.head m);

  # All fileSystems entries that are btrfs + have a subvol option.
  # Skip the top-level mount of /mnt/btrfs-root itself (subvolid=5 → root,
  # nothing to create).
  btrfsSubvolMounts =
    lib.filterAttrs (mount: cfg:
      cfg.fsType == "btrfs"
      && (extractSubvol (cfg.options or [])) != null
      && mount != "/mnt/btrfs-root"
    ) config.fileSystems;

  # Format as [{ mount, subvol }, ...] for iteration.
  toCreate = lib.mapAttrsToList (mount: cfg: {
    inherit mount;
    subvol = extractSubvol cfg.options;
  }) btrfsSubvolMounts;

in
{
  system.activationScripts.btrfsSubvolsAutocreate = lib.stringAfter [ "specialfs" ] ''
    echo "[btrfs-subvols] ensuring declared btrfs subvolumes exist on /mnt/btrfs-root"
    if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/btrfs-root 2>/dev/null; then
      echo "[btrfs-subvols] CRITICAL: /mnt/btrfs-root NOT MOUNTED — cannot create subvolumes."
      echo "[btrfs-subvols] Affected mounts (will silently fail with nofail):"
      ${lib.concatMapStringsSep "\n" (m: ''
        echo "  • ${m.mount} → subvol=${m.subvol}"
      '') toCreate}
      echo "[btrfs-subvols] Run from a working state with /mnt/btrfs-root mounted, then reboot."
      ${pkgs.util-linux}/bin/logger -t btrfs-subvols-autocreate -p user.crit \
        "/mnt/btrfs-root NOT MOUNTED — ${toString (builtins.length toCreate)} declared subvols cannot be created"
    else
      missing=0
      created=0
      ${lib.concatMapStringsSep "\n" (m: ''
        SUBVOL_PATH=/mnt/btrfs-root/${m.subvol}
        if ${pkgs.btrfs-progs}/bin/btrfs subvolume show "$SUBVOL_PATH" >/dev/null 2>&1; then
          : # already exists, silent
        else
          missing=$((missing+1))
          echo "[btrfs-subvols] CREATING ${m.subvol} (for ${m.mount})"
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$SUBVOL_PATH")"
          if ${pkgs.btrfs-progs}/bin/btrfs subvolume create "$SUBVOL_PATH"; then
            created=$((created+1))
            ${pkgs.util-linux}/bin/logger -t btrfs-subvols-autocreate -p user.warning \
              "created missing subvol ${m.subvol} for mount ${m.mount} — reboot required for mount to take effect"
          else
            echo "[btrfs-subvols] ERROR: failed to create ${m.subvol}"
            ${pkgs.util-linux}/bin/logger -t btrfs-subvols-autocreate -p user.err \
              "failed to create ${m.subvol} for ${m.mount}"
          fi
        fi
      '') toCreate}
      if [ "$created" -gt 0 ]; then
        echo "[btrfs-subvols] $created subvol(s) created — REBOOT to mount them properly."
        ${pkgs.util-linux}/bin/logger -t btrfs-subvols-autocreate -p user.warning \
          "$created subvol(s) created this activation — reboot recommended"
      else
        echo "[btrfs-subvols] all ${toString (builtins.length toCreate)} declared subvols already exist"
      fi
    fi
  '';
}
