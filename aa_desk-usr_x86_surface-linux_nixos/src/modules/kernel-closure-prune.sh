# kernel-closure-prune — retention: keep only the newest N kernel/initrd
# generations in the on-/boot closure cache
#
# Extracted from configuration_kernel_preservation.nix (kernelClosurePrune
# writeShellApplication / weekly timer + ExecStartPost of
# kernel-closure-preservation). Runtime-data-driven: cache dir and
# max_generations come from /etc/cloud-data/kernel-closure-preservation.json
# via jq at RUNTIME.
#
# SC2012 note: the original body parsed `ls -t1`. Rewritten to rank narinfo
# files by mtime with `find -printf '%T@ ...' | sort -rn` instead — never
# parses ls output.
#
# Fail-loud on a missing/unreadable CONFIG_JSON: this runs unattended off a
# weekly timer, so a broken config must surface instead of silently never
# pruning until /boot fills. NOT fatal on a missing cache dir
# (`[ -d "$CACHE" ] || exit 0`) — unchanged from before extraction: pruning a
# cache that was never created is a no-op, not an error.
set -eu

CONFIG_JSON="${KERNEL_CLOSURE_CONFIG_JSON:-/etc/cloud-data/kernel-closure-preservation.json}"

if [ ! -r "$CONFIG_JSON" ] || ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
  logger -t kernel-closure-prune -p user.err "$CONFIG_JSON missing or unreadable"
  exit 1
fi

CACHE="$(jq -r '.cache' "$CONFIG_JSON")"
MAX_GEN="$(jq -r '.max_generations' "$CONFIG_JSON")"
[ -d "$CACHE" ] || exit 0

# For each derivation family (linux, initrd), keep the N newest by mtime,
# drop the rest. The cache's narinfo files reference nars by hash; we delete
# both halves for each pruned path.
for family in linux initrd-linux; do
  old=$(find "$CACHE" -maxdepth 1 -name '*.narinfo' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2- \
        | xargs -r grep -l "StorePath:.*-$family-" \
        | tail -n +"$((MAX_GEN + 1))" || true)
  while IFS= read -r nf; do
    [ -n "$nf" ] || continue
    nar=$(grep '^URL:' "$nf" | cut -d' ' -f2)
    rm -f -- "$nf" "$CACHE/$nar"
    echo "[prune] dropped $nf and $CACHE/$nar"
  done << OLDNARINFOS
$old
OLDNARINFOS
done

echo "[prune] cache size now:"
du -sh "$CACHE" || true
