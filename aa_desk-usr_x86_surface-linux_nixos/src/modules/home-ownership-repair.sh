# home-ownership-repair — defensive per-user chown of known-fragile home
# paths, run on every nixos-rebuild activation.
#
# Extracted from configuration_home_ownership_repair.nix's `mkUserBlock`
# (a Nix function mapped over `managedUsers` via
# `lib.concatMapStrings mkUserBlock managedUsers`, producing one
# Nix-interpolated shell stanza per managed user). Now ONE runtime script
# that loops over the SAME managed-users / fragile-paths lists, read at
# RUNTIME via jq from /etc/cloud-data/home-ownership-repair.json — generated
# by builtins.toJSON straight from the Nix `managedUsers` / `fragilePaths`
# values, so the JSON can never drift from the Nix source of truth.
#
# See configuration_home_ownership_repair.nix for the full incident history
# (2026-05-16 root-owned .claude/hooks breaking home-manager; 2026-06-24
# NESTED-MOUNT HAZARD — Waydroid keystore corruption from a recursive chown
# crossing into a nested btrfs subvol mount).
#
# ⚠ NESTED-MOUNT HAZARD (preserved): `find -xdev` keeps BOTH detection and
# repair on the home subvol and never descends into a nested mount (e.g.
# ~/.local/share/waydroid = Android /data, legitimate foreign uids). Chown
# is applied to offending paths INDIVIDUALLY (never `-R`, which would cross
# the mount boundary).
#
# Fatality: a missing home dir or missing fragile path is silently skipped
# (not an error) — same as the original. A chown failure on one path is
# logged and does NOT abort processing of the remaining paths/users — same
# as the original, where every step was already gated behind `if/then/else`
# rather than a bare statement, so no `set -euo pipefail` behaviour change
# was needed here (unlike android-emulator/session-checkpoint, this body had
# no bare `cmd && action` statements to rewrite).
set -euo pipefail

CONFIG_JSON="${HOME_OWNERSHIP_REPAIR_CONFIG_JSON:-/etc/cloud-data/home-ownership-repair.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t home-ownership-repair -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

mapfile -t FRAGILE_PATHS < <(jq -r '.fragile_paths[]' "$CONFIG_JSON")

jq -c '.managed_users[]' "$CONFIG_JSON" | while IFS= read -r u; do
  name="$(printf '%s' "$u" | jq -r '.name')"
  group="$(printf '%s' "$u" | jq -r '.group')"
  home_dir="/home/$name"

  if [ -d "$home_dir" ]; then
    for path in "${FRAGILE_PATHS[@]}"; do
      target="$home_dir/$path"
      if [ -e "$target" ]; then
        # -xdev: NEVER cross a mount boundary. A nested subvol mount under a
        # fragile tree (e.g. ~/.local/share/waydroid = Android /data) carries
        # legitimate foreign uids and MUST NOT be chowned — see the
        # NESTED-MOUNT HAZARD note above.
        if find "$target" -xdev ! -user "$name" -print -quit 2>/dev/null | grep -q .; then
          echo "[home-ownership-repair] $name: wrong-owner files under $target — repairing (xdev-scoped)"
          # Journald (tag: home-ownership-repair) so a recurring root-write
          # leak is greppable post-boot: journalctl -t home-ownership-repair
          logger -t home-ownership-repair -p user.warning \
            "$name: foreign-owned files leaked under $target — repairing per-file chown to $name:$group (xdev; nested subvol mounts excluded)"
          find "$target" -xdev ! -user "$name" -print 2>/dev/null | head -n 5 | while IFS= read -r f; do
            echo "  $f"
            logger -t home-ownership-repair -p user.warning "  offending path: $f"
          done
          # Chown the offending paths INDIVIDUALLY (never `-R`, which would
          # descend into a nested mount). -print0|xargs -0 handles odd names.
          if find "$target" -xdev ! -user "$name" -print0 2>/dev/null \
               | xargs -0 -r chown "$name:$group"; then
            logger -t home-ownership-repair -p user.info \
              "$name: ownership repaired on $target (nested mounts untouched)"
          else
            logger -t home-ownership-repair -p user.err \
              "$name: chown FAILED on $target — home-manager apply may still break"
          fi
        fi
      fi
    done
  fi
done
