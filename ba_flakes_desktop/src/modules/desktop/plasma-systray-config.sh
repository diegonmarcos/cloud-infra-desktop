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
  # extraItems caps what the tray is allowed to know about at all.
  kwriteconfig6 --file "$APPLETS" --group Containments --group "$id" \
    --group General --key extraItems "$shown"

  echo "tray $((i + 1)) (containment $id): shown=[$shown]"
  echo "tray $((i + 1)) (containment $id): hidden=[$hidden]"
done
