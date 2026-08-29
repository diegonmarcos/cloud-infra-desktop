# Dedicated /tmp + /tmpfs — data-driven from cloud-data-disk-protection.json
#
# WHY: Previously /tmp was a plain directory on the 2G tmpfs root. Orphaned
# working copies from cloud-clean / verify scripts routinely filled it to 97%,
# blocking login and breaking systemd (see cloud-data-disk-protection.json
# mount "/" warning).
#
# HOW: This module reads `tmp_mounts.mounts` from the JSON. For each entry it
# generates:
#   1. fileSystems.<path> — either btrfs subvolume or tmpfs
#   2. systemd-tmpfiles "D! <path> <mode> root root <max_age> -" rule
#      (wipes contents on boot, age-cleanup between boots)
#   3. (btrfs only) activation-script branch that creates the subvolume on
#      /mnt/btrfs-root if missing — first `switch` creates it, reboot mounts it.
#
# RELOAD: ~/git/cloud-infra-desktop/aa_desk-usr_x86_surface-linux_nixos/build.sh (option r = switch).
# The JSON is copied into this module dir by build.sh `sync_cloud_data` before
# nixos-rebuild — same pattern as configuration_system-protection-disk.nix.
#
{ config, pkgs, lib, ... }:

let
  jsonPath = ./cloud-data-disk-protection.json;
  cfg =
    if builtins.pathExists jsonPath
    then builtins.fromJSON (builtins.readFile jsonPath)
    else { tmp_mounts = { mounts = []; }; };

  mounts = cfg.tmp_mounts.mounts or [];
  btrfsMounts = lib.filter (m: m.type == "btrfs") mounts;

  mkFileSystem = m:
    if m.type == "btrfs" then {
      device = m.device or "/dev/mapper/pool";
      fsType = "btrfs";
      options = [ "subvol=${m.subvol}" ] ++ (m.options or []);
    }
    else if m.type == "tmpfs" then {
      device = "none";
      fsType = "tmpfs";
      options = m.options or [ "size=${m.size or "1G"}" "mode=${m.mode or "1777"}" ];
    }
    else throw "configuration_tmp: unknown type '${m.type}' for ${m.path}";

  mkTmpfilesRule = m:
    "D! ${m.path} ${m.mode or "1777"} root root ${m.max_age or "3d"} -";
in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # FILESYSTEM MOUNTS (generated from JSON)
  # ═══════════════════════════════════════════════════════════════════════════
  fileSystems = lib.listToAttrs (map
    (m: lib.nameValuePair m.path (mkFileSystem m))
    mounts);

  # ═══════════════════════════════════════════════════════════════════════════
  # TMPFILES RULES — wipe on boot + age cleanup
  # ═══════════════════════════════════════════════════════════════════════════
  # D! = recreate dir + wipe contents on boot. Age argument ages remaining
  # files during periodic cleanup runs (so a 3-day-old file in /tmp still
  # gets removed even if the machine never reboots).
  systemd.tmpfiles.rules = map mkTmpfilesRule mounts;

  # ═══════════════════════════════════════════════════════════════════════════
  # BTRFS SUBVOLUME CREATION — first-switch bootstrap
  # ═══════════════════════════════════════════════════════════════════════════
  # Activation runs AFTER mounts. On first switch the /tmp btrfs mount will
  # fail (nofail → boot continues, /tmp stays on root tmpfs). This script
  # then creates the subvolume via /mnt/btrfs-root. Next reboot: mount works.
  system.activationScripts.tmpBtrfsSubvols = lib.mkIf (btrfsMounts != []) ''
    echo "[TMP] Ensuring btrfs subvolumes for declared /tmp mounts..."
    if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/btrfs-root 2>/dev/null; then
      echo "[TMP] WARNING: /mnt/btrfs-root not mounted, skipping subvol creation" >&2
    else
      ${lib.concatMapStringsSep "\n" (m: ''
        SUBVOL_PATH="/mnt/btrfs-root/${m.subvol}"
        if ! ${pkgs.btrfs-progs}/bin/btrfs subvolume show "$SUBVOL_PATH" >/dev/null 2>&1; then
          echo "[TMP] Creating subvolume ${m.subvol}..."
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$SUBVOL_PATH")" 2>/dev/null || true
          if ${pkgs.btrfs-progs}/bin/btrfs subvolume create "$SUBVOL_PATH"; then
            ${pkgs.coreutils}/bin/chmod ${m.mode or "1777"} "$SUBVOL_PATH"
            echo "[TMP] Created ${m.subvol} — reboot to mount ${m.path} on btrfs"
          else
            echo "[TMP] ERROR: failed to create ${m.subvol}" >&2
          fi
        else
          echo "[TMP] ${m.subvol} exists"
        fi
      '') btrfsMounts}
    fi
  '';
}
