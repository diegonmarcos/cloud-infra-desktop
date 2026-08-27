#!/usr/bin/env bash
# Data check for panels.json. Runs offline — no plasmashell, no D-Bus, no
# appletsrc. Replaces test-systray-config.sh, which tested a script that has
# been folded into plasma-panels-apply.sh.
#
# It checks the things that actually went wrong historically: a tray widget
# with no declared contents, an id declared in two trays, and an always_hidden
# id that some tray's shown list quietly re-shows (the complement is computed
# per tray, so a contradiction here is silent at runtime).
set -euo pipefail

JSON="${1:-$(dirname "$0")/panels.json}"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   — $1"; else echo "FAIL — $1: got '$2', want '$3'"; fail=1; fi; }

jq -e . "$JSON" >/dev/null && echo "ok   — panels.json is valid JSON"

check "every widget has a plugin" \
  "$(jq '[.panels[].widgets[] | select(has("plugin") | not)] | length' "$JSON")" 0

check "one shown list per systemtray widget" \
  "$(jq '[.panels[].widgets[] | select(.plugin == "org.kde.plasma.systemtray")] | length' "$JSON")" \
  "$(jq '[.panels[].widgets[] | select(has("shown"))] | length' "$JSON")"

check "only systemtray widgets carry a shown list" \
  "$(jq '[.panels[].widgets[] | select(has("shown") and .plugin != "org.kde.plasma.systemtray")] | length' "$JSON")" 0

check "no id is shown in two trays" \
  "$(jq '[.panels[].widgets[].shown // [] | .[]] | (length) - ([.[]] | unique | length)' "$JSON")" 0

check "no always_hidden id is also shown" \
  "$(jq '[.always_hidden[] as $h | [.panels[].widgets[].shown // [] | .[]] | index($h)] | map(select(. != null)) | length' "$JSON")" 0

check "every panel declares location and height" \
  "$(jq '[.panels[] | select((has("location") and has("height")) | not)] | length' "$JSON")" 0

# ── the runner's gate ────────────────────────────────────────────────────────
# 2026-08-27: the gate was (definition hash && live layout) and the tray step
# lives downstream of it, so once $STATE recorded a successful run the tray was
# never re-asserted. $STATE hashes panels.json; tray contents live in appletsrc,
# which plasmashell rewrites on its own. Both trays ended up with NO shownItems
# and NO hiddenItems at all — only plasmashell's own 15-entry stock lists — and
# every subsequent run logged "nothing to do". A gate must measure everything it
# guards, so the live tray is now a third term in it.
RUNNER="$(dirname "$0")/plasma-panels-apply.sh"

check "the runner compares live tray contents, not just the layout" \
  "$(grep -c 'live_tray=' "$RUNNER")" 1

check "the early-exit gate tests the tray as well as hash and layout" \
  "$(sed -n '/^if \[ "$cur_hash" = "$old_hash" \]/,/^fi$/p' "$RUNNER" | grep -c '\$live_tray" = "\$want_tray')" 1

# plasmashell treats an id absent from knownItems as new and shows it whatever
# hiddenItems says, so leaving that key alone leaves a second source of truth.
check "the runner owns knownItems" \
  "$(grep -c -- '--key knownItems' "$RUNNER")" 1

# Activation and the login autostart both fire this binary; the journal caught
# them in the same second. Concurrent passes through the rebuild both call
# panels().forEach(p => p.remove()) — the destroy/recreate plasmashell SEGV'd
# inside on 2026-08-22.
# Height is otherwise only ever assigned inside the rebuild, which the layout
# gate suppresses — so both panels sat at Plasma's default 30 while panels.json
# said 70 and 40, and every run reported "nothing to do".
check "the runner compares live geometry" \
  "$(grep -c 'live_geom=' "$RUNNER")" 1

check "the early-exit gate tests geometry too" \
  "$(sed -n '/^if \[ "$cur_hash" = "$old_hash" \]/,/^fi$/p' "$RUNNER" | grep -c '\$live_geom" = "\$want_geom')" 1

check "geometry is set in place, not via a rebuild" \
  "$(grep -c 'p.height = ' "$RUNNER")" 2

# plasma-manager never removes a generator it has stopped emitting, and
# run_all.sh globs scripts/*.sh — so a stale 2_desktop_script_panels.sh kept
# running `rm ~/.config/plasma-org.kde.plasma.desktop-appletsrc` at every login.
# w.writeConfig is otherwise reached only from the widget-add loop inside the
# rebuild, which the layout gate suppresses — so panels.json listed ten
# icontasks launchers while the live panel had nine, missing exactly
# waydroid-container-mobile.desktop, and every run said "nothing to do".
check "the runner compares live widget config" \
  "$(grep -c 'live_cfg=' "$RUNNER")" 1

check "the early-exit gate tests widget config too" \
  "$(sed -n '/^if \[ "$cur_hash" = "$old_hash" \]/,/^fi$/p' "$RUNNER" | grep -c '\$live_cfg" = "\$want_cfg')" 1

check "widget config is written in place, not via a rebuild" \
  "$(grep -c 'cfg_write_js' "$RUNNER")" 2

# plasmashell's print() emits no newline here, so N prints arrive as one blob;
# the separator has to be built JS-side or the readback cannot be compared.
check "the config readback joins its entries in JS" \
  "$(grep -c 'out.join' "$RUNNER")" 1

# every declared launcher must have a .desktop that exists, or it renders blank
check "every icontasks launcher names a real .desktop file" \
  "$(jq -r '[.panels[].widgets[] | select(.plugin=="org.kde.plasma.icontasks") | .config.General.launchers[]] | .[]' "$JSON" |
     sed 's|^applications:||' |
     while read -r d; do
       found=0
       for p in "$HOME/.nix-profile/share/applications" /run/current-system/sw/share/applications "$HOME/.local/share/applications"; do
         [ -f "$p/$d" ] && found=1
       done
       [ "$found" = 0 ] && echo "$d"
     done | wc -l | tr -d ' ')" 0

check "the generated plasma-manager dirs are pruned before they are rewritten" \
  "$(grep -c 'plasmaManagerPrune' "$(dirname "$0")/plasma.nix")" 1

check "the prune runs before plasma-manager regenerates" \
  "$(sed -n '/plasmaManagerPrune/,/'"''"'/p' "$(dirname "$0")/plasma.nix" | grep -c 'entryBetween \[ "configure-plasma" \]')" 1

check "the runner serialises itself" \
  "$(grep -c '^flock 9' "$RUNNER")" 1

exit "$fail"
