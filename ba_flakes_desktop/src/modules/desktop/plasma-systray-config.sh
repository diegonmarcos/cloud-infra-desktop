# Apply systray-items.json to the private systemtray containments of
# plasma-org.kde.plasma.desktop-appletsrc.
#
# Runs from plasma-systray-config.service, ordered Before plasmashell.
#
# Why not a home-manager activation (what this replaces):
#   plasmashell owns the appletsrc while it runs and writes its whole in-memory
#   state back over the file on exit. Anything written to a live session is
#   discarded at logout -- which is how tray 1 lost its hiddenItems= line
#   outright and both trays fell back to showing every icon. Writing before
#   plasmashell starts means it reads our lists instead of overwriting them.
#
# Why hiddenItems is computed rather than listed:
#   the tray's default for an id it was never told about is *shown*. A fixed
#   hidden list can only hide what we predicted, so every newly discovered SNI
#   leaked into tray 1. hidden = everything either tray knows about or we
#   declare, minus this tray's shown list.

APPLETS="${SYSTRAY_APPLETS_FILE:-$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc}"
JSON="${SYSTRAY_ITEMS_JSON:-$HOME/.local/share/systray-items.json}"

if [ ! -f "$APPLETS" ]; then
  echo "no $APPLETS yet (first login) -- nothing to configure"
  exit 0
fi
if [ ! -f "$JSON" ]; then
  echo "missing $JSON" >&2
  exit 1
fi

# Private systemtray containments, in panel order (tray 1 first). The id is
# only latched on a top-level [Containments][N] header, so applet subsections
# of a panel cannot be mistaken for a tray.
mapfile -t TRAYS < <(awk '
  /^\[Containments\]\[[0-9]+\]$/ { id = gensub(/.*\[([0-9]+)\]$/, "\\1", "g"); next }
  /^plugin=org\.kde\.plasma\.private\.systemtray$/ { if (id != "") print id }
' "$APPLETS")

if [ "${#TRAYS[@]}" -eq 0 ]; then
  echo "no private systemtray containments in $APPLETS" >&2
  exit 1
fi

# Every id either tray has ever seen, plus everything we declare.
universe=$(
  {
    for id in "${TRAYS[@]}"; do
      for key in knownItems extraItems shownItems hiddenItems; do
        kreadconfig6 --file "$APPLETS" --group Containments --group "$id" \
          --group General --key "$key"
      done
    done
    jq -r '[.trays[].shown[], .always_hidden[]] | .[]' "$JSON"
    # ...plus every SNI registered on the bus RIGHT NOW.
    #
    # The two sources above are both retrospective: Plasma's knownItems only
    # lists ids it has already recorded, and the JSON only lists ids a human
    # thought to declare. An SNI that is live but in neither is in no list at
    # all, and the tray's default for an unknown id is *shown* -- so it leaks
    # into the visible strip of BOTH trays. That is exactly how `my-ai-usage`
    # (a separate process from the my-konsole tray daemon) rendered twice and
    # read as "my-ai shown double" (2026-08-22).
    #
    # Enumerating the live bus closes the class rather than the instance: a
    # newly discovered SNI enters the universe on its first apply, so it is
    # hidden-by-default and only becomes visible when declared in a shown list.
    # Best-effort: no bus, no busctl, or no items simply contributes nothing.
    #
    # `|| true` and awk-instead-of-grep keep this branch genuinely best-effort,
    # as the paragraph above claims it is. Under errexit+pipefail neither was
    # true by accident: a bus with no SNIs registered yet (this unit runs
    # BEFORE plasmashell, so that is the normal case at login) makes grep exit
    # 1 and takes the whole applier down with it.
    if command -v busctl >/dev/null 2>&1; then
      {
        busctl --user list --no-legend 2>/dev/null |
          awk '/^org\.kde\.StatusNotifierItem-/ { print $1 }' |
          while read -r _svc; do
            busctl --user get-property "$_svc" /StatusNotifierItem \
              org.kde.StatusNotifierItem Id 2>/dev/null |
              sed -n 's/^s "\(.*\)"$/\1/p'
          done
      } || true
    fi
  } | tr ',' '\n' | sed '/^$/d' | sort -u
)

for i in "${!TRAYS[@]}"; do
  id="${TRAYS[$i]}"

  if [ "$(jq -r --argjson i "$i" 'has("trays") and (.trays | length > $i)' "$JSON")" != "true" ]; then
    echo "tray $((i + 1)) (containment $id): not declared in $JSON -- left alone"
    continue
  fi

  shown=$(jq -r --argjson i "$i" '.trays[$i].shown | join(",")' "$JSON")
  hidden=$(printf '%s\n' "$universe" |
    awk -v s=",$shown," 'index(s, "," $0 ",") == 0' | paste -sd,)

  kwriteconfig6 --file "$APPLETS" --group Containments --group "$id" \
    --group General --key shownItems "$shown"
  kwriteconfig6 --file "$APPLETS" --group Containments --group "$id" \
    --group General --key hiddenItems "$hidden"
  # extraItems is a list of PLASMOID ids to instantiate in the tray -- it is not
  # a visibility key and it does not cap anything. Only shownItems/hiddenItems
  # above decide what renders. Feeding it SNI ids is a silent no-op: plasmashell
  # cannot resolve them to installed packages, so it drops them on its next
  # write. Tray 1's entire extraItems line was being deleted on every session
  # for exactly that reason, which made the applier look like it had failed
  # when it had not.
  #
  # ponytail: reverse-DNS as the plasmoid test. Plasmoid ids are KPackage
  # directory names and dotted by convention; SNI ids are process-chosen and
  # ours are bare ("cloud-systray"). If an SNI ever ships a dotted Id it just
  # gets written and pruned again -- back to today's harmless no-op, not a
  # regression. Swap in a `kpackagetool6 --list` check if that ever matters.
  #
  # awk, not grep, and that is load-bearing: grep exits 1 when nothing matches,
  # and under errexit+pipefail that aborts the whole script. Tray 1 is all bare
  # SNI ids, so it matches nothing on every single run -- a grep here would kill
  # the applier before tray 2 was ever configured. awk exits 0 either way.
  plasmoids=$(printf '%s\n' "$shown" | tr ',' '\n' | awk '/\./' | paste -sd,)
  kwriteconfig6 --file "$APPLETS" --group Containments --group "$id" \
    --group General --key extraItems "$plasmoids"

  echo "tray $((i + 1)) (containment $id): shown=[$shown]"
  echo "tray $((i + 1)) (containment $id): hidden=[$hidden]"
done
