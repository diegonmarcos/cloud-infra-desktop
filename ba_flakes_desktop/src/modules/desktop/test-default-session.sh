#!/usr/bin/env bash
# test-default-session.sh — proves the declarative default-session feature.
#
# Covers everything that can be checked WITHOUT a real logout:
#   1. default-session.json is valid JSON with the expected shape
#   2. every window references an app that exists in the .apps registry
#   3. every registry exec resolves on PATH (so a login won't silently no-op)
#   4. launcher passes `bash -n` and a --dry-run lists all declared windows
#   5. the generated KWin positioning JS is brace-balanced
#   6. the autostart .desktop + loginMode are declared in the nix sources
#
# The final stage (windows actually land on the right desktops/halves at login)
# was verified live during development via the KWin/Konsole DBus readback; it
# can't be asserted here because it needs a fresh login. Run manually:
#   bash default-session-launcher.sh --desktop=1   # then inspect, then close
set -u
DIR="$(dirname "$(readlink -f "$0")")"
JSON="$DIR/default-session.json"
LAUNCHER="$DIR/default-session-launcher.sh"
NIX="$DIR/default-session.nix"
PASS=0; FAIL=0
ok(){ printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "── 1. JSON shape ──"
if jq -e . "$JSON" >/dev/null 2>&1; then ok "valid JSON"; else no "invalid JSON"; fi
jq -e '.apps and .desktops and .fallback' "$JSON" >/dev/null 2>&1 && ok "has .apps/.desktops/.fallback" || no "missing top-level keys"
[ "$(jq '.desktops|length' "$JSON")" = 4 ] && ok "4 desktops" || no "expected 4 desktops"

echo "── 2. every window's app is registered ──"
miss="$(jq -r '[.desktops[].windows[].app] - (.apps|keys) | unique[]' "$JSON" 2>/dev/null)"
[ -z "$miss" ] && ok "all windows reference a registered app" || no "unregistered apps: $miss"

echo "── 3. registry execs resolve on PATH ──"
export PATH="/run/current-system/sw/bin:$HOME/.nix-profile/bin:/run/wrappers/bin:/etc/profiles/per-user/$USER/bin:$PATH"
while read -r exe; do
  [ -z "$exe" ] && continue
  if command -v "$exe" >/dev/null 2>&1; then ok "exec '$exe' found"; else no "exec '$exe' NOT on PATH"; fi
done < <(jq -r '.apps[] | (.exec // empty)' "$JSON" | sort -u)

echo "── 4. launcher syntax + dry-run ──"
bash -n "$LAUNCHER" && ok "bash -n clean" || no "syntax error"
plan="$(bash "$LAUNCHER" --dry-run 2>&1 | grep -c '^.*PLAN ')"
want="$(jq '[.desktops[].windows[]]|length' "$JSON")"
[ "$plan" = "$want" ] && ok "dry-run plans all $want windows" || no "dry-run planned $plan, expected $want"

echo "── 5. generated KWin JS is brace-balanced ──"
# reproduce the embedded JS region and count braces
js="$(sed -n '/cat <<.\?JS.\?$/,/^JS$/p' "$LAUNCHER" | sed '1d;$d')"
ob="$(printf '%s' "$js" | tr -cd '{' | wc -c)"; cb="$(printf '%s' "$js" | tr -cd '}' | wc -c)"
[ "$ob" = "$cb" ] && [ "$ob" -gt 0 ] && ok "KWin JS braces balanced ($ob)" || no "KWin JS brace mismatch ($ob/$cb)"

echo "── 6. nix declares autostart + emptySession ──"
grep -q 'autostart/default-session.desktop' "$NIX" && ok "autostart .desktop declared" || no "no autostart entry"
grep -q 'DEFAULT_SESSION_JSON=' "$NIX" && ok "autostart passes DEFAULT_SESSION_JSON (deployed json path)" || no "json path not passed — deployed launcher won't find its data"
grep -q 'loginMode = "emptySession"' "$NIX" && ok "loginMode=emptySession declared" || no "loginMode not set"
if grep -qE '^[^#]*loginMode *=' "$DIR/session-restore.nix"; then
  no "session-restore.nix still has an active loginMode assignment (double-definition risk)"
else
  ok "session-restore.nix has no active loginMode assignment (no conflict)"
fi

echo "── 7. app-not-found fallback (missing binary → skip, exit 0, no hang) ──"
ghost="$(mktemp)"
cat > "$ghost" <<'EOF'
{ "fallback": { "per_app_launch_timeout_sec": 5 },
  "apps": { "ghost": { "exec": "nonexistent-bin-xyz", "match_class": "ghost", "arg_mode": "none" } },
  "desktops": [ { "id": 9, "split": "full", "windows": [ { "cell": "full", "app": "ghost" } ] } ] }
EOF
out="$(DEFAULT_SESSION_JSON="$ghost" timeout 30 bash "$LAUNCHER" 2>&1)"; rc=$?
echo "$out" | grep -q 'NOT FOUND' && ok "missing binary logged as NOT FOUND" || no "missing binary not reported"
[ "$rc" = 0 ] && ok "launcher exits 0 despite missing app (never fails the session)" || no "launcher exited $rc"
rm -f "$ghost"

echo "── 8. paths arg_mode: missing folders skipped, launch still proceeds ──"
rec="$(mktemp)"; recout="$(mktemp)"; pjson="$(mktemp)"
cat > "$rec" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$recout"
EOF
chmod +x "$rec"
cat > "$pjson" <<EOF
{ "fallback": { "per_app_launch_timeout_sec": 3, "position_passes": 1, "position_interval_sec": 0.2 },
  "apps": { "rec": { "exec": "$rec", "match_class": "rec", "arg_mode": "paths", "fixed_args": ["--new-window"] } },
  "desktops": [ { "id": 9, "split": "full", "windows": [
    { "cell": "full", "app": "rec", "args": ["/mnt", "/no/such/folder/xyz123", "/tmp"] } ] } ] }
EOF
out="$(DEFAULT_SESSION_JSON="$pjson" timeout 30 bash "$LAUNCHER" 2>&1)"
echo "$out" | grep -q "skip missing folder '/no/such/folder/xyz123'" && ok "missing folder skipped + logged" || no "missing folder not handled"
argv="$(cat "$recout" 2>/dev/null)"
case "$argv" in
  *"/no/such/folder/xyz123"*) no "missing folder leaked into argv: $argv" ;;
  *"/mnt"*"/tmp"*)             ok "only existing folders passed: [$argv]" ;;
  *)                          no "unexpected argv: [$argv]" ;;
esac
rm -f "$rec" "$recout" "$pjson"

echo
echo "════════ $PASS passed, $FAIL failed ════════"
[ "$FAIL" = 0 ]
