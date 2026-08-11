# hardware_filesystems_nosnap.nix — regenerable churn OUT of the snapshot window.
#
# WHY (2026-08-11 incident)
# ─────────────────────────
# Deleting 9.1G of octocode index freed EXACTLY ZERO bytes. So did ~2G of
# ex-submodule clones. df sat at 93% through the whole cleanup, and earlier the
# disk-watchdog's emergency tier reported "0 store paths deleted, 0.00 MiB
# freed" and fell through to FREEZING workload.slice.
#
# Nothing was broken. session-checkpoint.timer snapshots @home-diego every 6h
# and keeps the newest 3 (retention_count, hard cap). A read-only snapshot pins
# every extent it references, so anything deleted from @home-diego stays on disk
# until all 3 snapshots holding it rotate out — up to 18h. Reclaim is
# STRUCTURALLY INCAPABLE of freeing snapshotted extents, which is why the
# watchdog's ladder had nothing to give.
#
# cloud-data-session-checkpoint.json already names the escape hatch:
#   "Nested subvolumes (e.g. container storage inside home) are automatically
#    excluded by btrfs — desirable, they are not session state."
#
# So: give each regenerable cache its own subvolume. btrfs never descends into a
# nested subvolume when snapshotting the parent, so these are excluded from every
# checkpoint. Deleting them frees space IMMEDIATELY, and the 6-hourly snapshot
# stops carrying ~35G of build/index churn it was never meant to protect.
#
# WHAT IS DELIBERATELY NOT PROTECTED
# ──────────────────────────────────
# Everything here is excluded from session checkpoints. A crash loses whatever
# is in these paths since it is not session state:
#   - caches/indexes: rebuilt on next use (octocode restores from GHCR via
#     cloud-cgc-db-pull.sh — GHCR is the single upstream, not this dir)
#   - ~/git: UNCOMMITTED WORK IS NOT CHECKPOINTED ANY MORE. Accepted 2026-08-11:
#     it is the single largest churn source (24G) and everything in it is pushed.
#     The tradeoff is real — commit before you reboot.
#
# MIGRATION IS NOT AUTOMATIC — READ BEFORE SWITCHING
# ──────────────────────────────────────────────────
# configuration_btrfs_subvols_autocreate.nix creates a declared subvol only when
# the path is absent or an EMPTY dir. Every path below currently exists as a
# plain dir WITH DATA, so activation will log CRIT and SKIP it, and the mount
# will keep failing (nofail, so boot still succeeds — it just silently does
# nothing). Run ./migrate-nosnap-subvols.sh FIRST; it does the
# create-new/reflink-copy/swap dance the autocreate module refuses to do
# implicitly. Order matters: delete the pinning snapshots BEFORE migrating, or
# the copies have nowhere to go.
{ config, lib, pkgs, ... }:

let
  # Source of truth. path = where it mounts; subvol = where it lives under
  # /mnt/btrfs-root. All under @nosnap/ so `btrfs subvolume list` shows at a
  # glance what is outside the checkpoint window.
  #
  # ADDING ONE: append here, run the migration script, switch. Nothing else.
  # The rule for what belongs: it must be REGENERABLE, and losing it on a crash
  # must cost only time.
  # `mode` drives the tmpfiles rule below. A btrfs subvolume root is created
  # root:root 0755, so WITHOUT that rule every one of these mounts lands
  # unwritable by the user who owns everything under it.
  nosnap = [
    { path = "/home/diego/git";                        subvol = "@nosnap/git";              mode = "0755"; note = "24G, biggest churn source; all pushed"; }
    { path = "/home/diego/.local/share/octocode";      subvol = "@nosnap/octocode";         mode = "0700"; note = "9.1G index; canonical copy is GHCR cloud-cgc-mcp-octocode-db"; }
    { path = "/home/diego/.local/share/claude";        subvol = "@nosnap/claude";           mode = "0700"; note = "857M agent state"; }
    { path = "/home/diego/.local/share/antigravity-ide"; subvol = "@nosnap/antigravity-ide"; mode = "0700"; note = "732M IDE state"; }
    { path = "/home/diego/.cache";                     subvol = "@nosnap/cache";            mode = "0755"; note = "definitionally disposable"; }
    { path = "/home/diego/.cargo";                     subvol = "@nosnap/cargo";            mode = "0755"; note = "rebuildable"; }
    { path = "/home/diego/.gradle";                    subvol = "@nosnap/gradle";           mode = "0755"; note = "rebuildable"; }
    { path = "/home/diego/.node_modules";              subvol = "@nosnap/node_modules";     mode = "0755"; note = "rebuildable"; }
  ];

  # nofail + a short device-timeout everywhere: a cache that fails to mount must
  # never block boot on an 8GB laptop whose whole recovery story depends on
  # reaching a shell. Same posture as /home/diego above.
  mkMount = e: lib.nameValuePair e.path {
    device = "/dev/mapper/pool";
    fsType = "btrfs";
    options = [
      "subvol=${e.subvol}"
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=10s"
    ];
  };
in
{
  fileSystems = lib.listToAttrs (map mkMount nosnap);

  # Own the MOUNTED subvolume roots (2026-08-11).
  #
  # A btrfs subvolume root is born root:root 0755. Declaring the mount is not
  # enough: once mounted, the directory the user sees is that root, so
  # /home/diego/.cache became unwritable by diego and everything that caches
  # there broke at once — `nix develop` died with "creating directory
  # '/home/diego/.cache/nix': Permission denied" (and, because it exits 1 with
  # NO message, every build using it appeared to fail silently), starship
  # spammed "Unable to create log dir", and plasmashell could not build its
  # icon cache so the whole panel rendered blank.
  #
  # Fixing it by hand does not survive: a switch re-asserts the subvolume and
  # the ownership reverts, which is exactly what happened tonight. It has to be
  # declared. systemd-tmpfiles-setup runs After=local-fs.target, i.e. after
  # these (nofail) mounts, so the rule applies to the mounted root and not to
  # the directory hidden underneath it.
  systemd.tmpfiles.rules =
    map (e: "d ${e.path} ${e.mode} diego users - -") nosnap;
}
