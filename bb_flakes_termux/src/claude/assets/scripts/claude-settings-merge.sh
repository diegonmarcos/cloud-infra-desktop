# claude-settings-merge — merge settings.base.json + settings.<overlay>.json
# READ FROM THE WORKING CHECKOUT AT ACTIVATION TIME, not through a pinned
# flake input. A flake input (`my-ai = { url = "github:...?dir=da_my-ai"; }`)
# only updates on `nix flake update my-ai` + a switch; the lock can (and did,
# 2026-08-18 to 2026-08-20) sit stale for days while the SoT moves on, and
# nothing says so — the deployed settings just silently lag. Reading the
# checkout directly collapses "edit -> commit + push -> flake update -> switch"
# down to "commit + push -> switch", and a missing SoT now fails LOUD instead
# of quietly keeping the last-pinned copy. Mirrors ba_flakes_desktop's
# claudeSettings activation (home.activation.claudeSettings there).
#
# NO FALLBACK to a bundled/pinned copy, deliberately: a fallback is a second
# source that can disagree, and disagreeing silently is the exact bug this
# replaces. One SoT, or a loud error.
#
# Env contract: REPO_SOT (dir holding settings.base.json + $OVERLAY)
# OVERLAY (overlay filename, e.g. settings.termux.json) DST (output path)
# HOME_DIR (substituted for @HOME@ placeholders) SED_BIN JQ_BIN (tool paths,
# default to PATH so this script is directly runnable/testable standalone).
set -u
SED_BIN="${SED_BIN:-sed}"
JQ_BIN="${JQ_BIN:-jq}"

if [ ! -r "$REPO_SOT/settings.base.json" ] || [ ! -r "$REPO_SOT/$OVERLAY" ]; then
  echo "[claude-settings] FATAL: SoT missing at $REPO_SOT ($OVERLAY)" >&2
  echo "[claude-settings] $DST left UNCHANGED. Clone the repo there, or set CLAUDE_SOT_DIR." >&2
  exit 1
fi

TMP="$DST.merge-tmp.$$"
# jq's * is a RECURSIVE object merge, matching lib.recursiveUpdate — a plain +
# replaces whole sub-objects and would silently drop base keys the overlay
# does not restate.
if ! "$SED_BIN" "s|@HOME@|$HOME_DIR|g" "$REPO_SOT/settings.base.json" \
     | "$JQ_BIN" -s --slurpfile ov "$REPO_SOT/$OVERLAY" \
         --arg overlay "$OVERLAY" \
         '.[0] * $ov[0] * {_generated: ("GENERATED FILE — DO NOT EDIT. Source: da_my-ai/src/data/claude/settings.base.json + " + $overlay + " (the ONE SoT, read from the working checkout at activation). Engine: bb_flakes_termux/src/claude/claude.nix. Rebuild: bb_flakes_termux/build.sh switch.")}' \
         > "$TMP" 2>/dev/null || [ ! -s "$TMP" ]; then
  rm -f "$TMP"
  echo "[claude-settings] FATAL: merge of base+overlay failed — $DST left UNCHANGED" >&2
  exit 1
fi
mv "$TMP" "$DST"
chmod 600 "$DST"
echo "[claude-settings] $DST written from $REPO_SOT (single SoT)"
