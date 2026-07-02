#!/usr/bin/env bash
# da_browser-qute — build engine
#
# This project ships no compiled artifact — it's a pure NixOS / home-manager
# config layer on top of upstream qutebrowser. The "build" is a JSON-schema
# check + a Nix flake check; "install" is a noop (the home-manager module
# does the real work when consumed by the user's home flake).
#
# Usage:
#   ./build.sh check      # validate JSON syntax + Nix flake evaluation
#   ./build.sh lint-json  # JSON syntax only (fast)
#   ./build.sh print-config  # show resolved settings/search/keybindings/quickmarks
#   ./build.sh diff       # compare current vs deployed state in ~/.config/qutebrowser
#   (default = check)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
LOG="$ROOT/build.log"
CONFIG="$ROOT/build.json"

get() { node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { printf '\033[0;31m[%s] ERROR: %s\033[0m\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

CONFIGS_DIR="$ROOT/$(get paths.configs)"
[ -d "$CONFIGS_DIR" ] || die "configs dir missing: $CONFIGS_DIR"

cmd="${1:-check}"

case "$cmd" in
  lint-json)
    log "validating JSON files in $CONFIGS_DIR"
    rc=0
    for f in "$CONFIGS_DIR"/*.json; do
      if node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" 2>/dev/null; then
        log "  ok  $(basename "$f")"
      else
        printf '\033[0;31m  bad %s\033[0m\n' "$(basename "$f")"
        rc=1
      fi
    done
    [ "$rc" -eq 0 ] || die "JSON validation failed"
    ;;

  dashboard)
    # Regenerate the committed start-page dashboard (dist/dashboard.html) from the
    # bookmark folder SoT + cloud-data (build-flakes_desktop.json). The cloud folders
    # (source:"cloud:*") resolve here — without this step the committed dashboard goes
    # stale and the cloud service URLs (*.diegonmarcos.com + api/app) go missing.
    log "regenerating dashboard (bookmarks + cloud-data services)"
    bash "$SRC/dashboard/gen-dashboard.sh"
    ;;

  check)
    "$0" lint-json
    "$0" dashboard
    log "evaluating flake (--no-build)"
    cd "$SRC"
    nix flake check --no-build --no-write-lock-file 2>&1 | tail -10
    log "ok"
    ;;

  print-config)
    log "resolved settings/search/keybindings/quickmarks (post _description strip)"
    for slot in settings search-engines keybindings bookmarks; do
      f="$CONFIGS_DIR/qute-${slot}.json"
      [ -f "$f" ] || continue
      printf '\n=== %s ===\n' "$(basename "$f")"
      node -e "
        const c=require('$f');
        const strip = v => Array.isArray(v) ? v.map(strip)
          : (v && typeof v === 'object')
            ? Object.fromEntries(Object.entries(v).filter(([k])=>!k.startsWith('_description')&&!k.startsWith('_comment')).map(([k,vv])=>[k,strip(vv)]))
            : v;
        console.log(JSON.stringify(strip(c), null, 2));
      "
    done
    ;;

  diff)
    log "diff: src/2_configs vs ~/.config/qutebrowser/config.py (rough)"
    if [ -f "$HOME/.config/qutebrowser/config.py" ]; then
      log "config.py size: $(wc -l < "$HOME/.config/qutebrowser/config.py") lines"
    else
      log "no ~/.config/qutebrowser/config.py — has home-manager switched yet?"
    fi
    "$0" print-config | tail -50
    ;;

  *)
    die "Unknown command: $cmd  (use: lint-json | check | print-config | diff)"
    ;;
esac
