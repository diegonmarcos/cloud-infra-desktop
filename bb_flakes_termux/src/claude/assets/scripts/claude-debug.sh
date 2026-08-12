# claude--debug — full startup-diagnostic battery for claude on this phone.
# Deployed as `claude--debug` on PATH (writeShellScriptBin in flake.nix).
#
# Runs every probe from the 2026-08-08 debugging session in one shot:
#   0. environment (versions, TERM/SHELL, API-key presence, session-store size)
#   1. shell-snapshot cost           (bash -lic true — measures the $SHELL spawn
#                                     claude does at startup, incl. guardrails BASH_ENV)
#   2. probe A — core, no TUI       (claude --bare -p, API key stripped)
#   3. probe B — TUI, no plugins    (claude --bare, 60s auto-kill, --debug-file)
#   4. probe C — TUI, everything    (claude, 120s auto-kill, --debug-file)
#   5. verdict + ship the log:
#        ~/git/cloud-data/logs/claude--debug.log   (committed + pushed)
#        ~/git/unix/1_reports/claude--debug.log    (mirror, committed + pushed —
#                                                   the copy Claude-in-the-cloud can pull)
#
# IMPORTANT while it runs: if a Claude UI appears during probe B or C, startup
# WORKS — it will auto-close when the probe timer fires. Don't type into it.
set -u

# ONE output convention (1_cicd/src/scripts/cloud-data-paths.sh):
#   logs/claude--debug.log      this run's narrative     (app log)
#   reports/claude--debug.json  machine-readable verdict (probe result)
#   journal/claude--debug.text  logcat tail              (OS journal)
CDP="$HOME/git/unix/1_cicd/dist/scripts/cloud-data-paths.sh"
if [ -r "$CDP" ]; then
  . "$CDP"
  LOG="$(cd_log claude--debug)"
  REPORT="$(cd_report claude--debug)"
  JOURNAL="$(cd_journal claude--debug)"
else
  LOG="$HOME/claude--debug.log"; REPORT="$HOME/claude--debug.json"; JOURNAL="$HOME/claude--debug.text"
fi
CLOUDDATA_DIR="$(dirname "$LOG")"
UNIX_REPORT_DIR="$HOME/git/unix/1_reports"
TUIBARE="${LOG%.log}.tui-bare.log"
TUIFULL="${LOG%.log}.tui-full.log"
REAL="$HOME/.nix-profile/bin/claude"

: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

hdr() { printf '\n══════ %s ══════\n' "$*"; }

hdr "claude--debug $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "log: $LOG"

# ── 0. environment ─────────────────────────────────────────────────
hdr "0. environment"
uname -a
echo "TERM=${TERM:-unset}  SHELL=${SHELL:-unset}"
echo "claude binary : $REAL"
echo "version       : $(timeout 30 "$REAL" --version 2>&1)"
echo "ANTHROPIC_API_KEY in env: $([ -n "${ANTHROPIC_API_KEY:-}" ] && echo YES || echo no)"
echo "session store :"
du -sh "$HOME/.claude" "$HOME/.claude/projects" 2>/dev/null
echo ".claude.json  : $(stat -c%s "$HOME/.claude.json" 2>/dev/null || echo '?') bytes"
echo "project dirs  : $(ls "$HOME/.claude/projects" 2>/dev/null | wc -l)"

# ── 1. shell-snapshot cost ─────────────────────────────────────────
hdr "1. shell-snapshot cost (bash -lic true — what claude spawns at startup)"
t0=$SECONDS
timeout 60 bash -lic true; rc=$?
R_SHELL_RC=$rc; R_SHELL_S=$((SECONDS-t0))
echo "bash -lic true: rc=$rc took $((SECONDS-t0))s  (124 = HUNG >60s → snapshot is the blocker)"

# ── 2. probe A: core, no TUI ───────────────────────────────────────
hdr "2. probe A — core no-TUI (claude --bare -p, no API key)"
t0=$SECONDS
timeout 90 env -u ANTHROPIC_API_KEY "$REAL" --bare -p 'say hi' </dev/null; rc=$?
R_A_RC=$rc; R_A_S=$((SECONDS-t0))
echo "probe A: rc=$rc took $((SECONDS-t0))s  (fast, any rc = core fine · 124 = core hangs even without TUI)"

# ── 3/4. TUI probes — need the real terminal, not our tee pipe ─────
run_tui() { # run_tui <label> <secs> <dbgfile> <bare?>
  _label=$1; _secs=$2; _dbg=$3; _bare=$4
  hdr "$_label (auto-kill ${_secs}s — if a Claude UI appears, startup WORKS; don't type)"
  if ! { exec 9</dev/tty; } 2>/dev/null; then echo "no usable tty — skipped"; return; fi
  exec 9<&-
  : > "$_dbg"
  t0=$SECONDS
  if [ "$_bare" = yes ]; then
    timeout "$_secs" env -u ANTHROPIC_API_KEY "$REAL" --bare --debug-file "$_dbg" </dev/tty >/dev/tty 2>&1; rc=$?
  else
    timeout "$_secs" "$REAL" --debug-file "$_dbg" </dev/tty >/dev/tty 2>&1; rc=$?
  fi
  case "$_bare" in yes) R_B_RC=$rc; R_B_S=$((SECONDS-t0));; *) R_C_RC=$rc; R_C_S=$((SECONDS-t0));; esac
  echo "$_label: rc=$rc took $((SECONDS-t0))s  (124 = auto-killed: either painted fine OR hung — see UI note above)"
  echo "-- last 12 debug lines ($_dbg):"
  tail -12 "$_dbg" 2>/dev/null | sed 's/^/  │ /'
}
run_tui "3. probe B — TUI --bare, no plugins/MCP, no API key" 60  "$TUIBARE" yes
run_tui "4. probe C — TUI full (plugins+MCP+API key)"        120 "$TUIFULL" no

# ── 5. verdict + ship ──────────────────────────────────────────────
hdr "5. verdict hints"
echo "read like this:"
echo "  step 1 slow/124        → \$SHELL snapshot (guardrails BASH_ENV / proot) is the blocker"
echo "  probe A slow/124       → core startup broken even headless (session store / auth / IO)"
echo "  A fast, B stalls       → TUI/terminal handshake (Termux) — compare B's last debug line"
echo "  A+B fine, C stalls     → plugin/MCP layer — compare C's last debug line vs B's"
echo "  UI appeared in B or C  → claude STARTS — remaining problem is only slowness"

hdr "os journal"
if command -v logcat >/dev/null 2>&1; then
  timeout 20 logcat -d -t 400 > "$JOURNAL" 2>/dev/null \
    && echo "logcat tail (400 lines) → $JOURNAL" \
    || echo "logcat present but capture failed"
else
  echo "no logcat on PATH — journal skipped"; : > "$JOURNAL" 2>/dev/null || true
fi

hdr "report"
# Machine-readable verdict — a PROBE result, so it lands in reports/ as JSON
# for anything downstream (dashboard, MCP, CI gate) to consume.
printf '{\n  "tool": "claude--debug",\n  "utc": "%s",\n  "claude_version": "%s",\n  "api_key_in_env": %s,\n  "probes": {\n    "shell_snapshot": {"rc": %s, "seconds": %s},\n    "core_headless":  {"rc": %s, "seconds": %s},\n    "tui_bare":       {"rc": %s, "seconds": %s},\n    "tui_full":       {"rc": %s, "seconds": %s}\n  },\n  "artifacts": {"log": "%s", "journal": "%s", "tui_bare": "%s", "tui_full": "%s"}\n}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(timeout 30 "$REAL" --version 2>/dev/null | head -1)" \
  "$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo true || echo false)" \
  "${R_SHELL_RC:-null}" "${R_SHELL_S:-null}" \
  "${R_A_RC:-null}" "${R_A_S:-null}" \
  "${R_B_RC:-null}" "${R_B_S:-null}" \
  "${R_C_RC:-null}" "${R_C_S:-null}" \
  "$LOG" "$JOURNAL" "$TUIBARE" "$TUIFULL" > "$REPORT" 2>/dev/null \
  && echo "verdict → $REPORT" || echo "report write failed"

hdr "shipping logs"
# cloud-data: the three artifacts are ALREADY written in place (logs/,
# reports/, journal/) — nothing to copy, just publish them.
if [ -d "$HOME/git/cloud-data/.git" ]; then
  ( cd "$HOME/git/cloud-data" \
    && git add logs/claude--debug* reports/claude--debug* journal/claude--debug* >/dev/null 2>&1 \
    && git commit -q -m "claude--debug $(date -u +%FT%TZ)" \
         -- logs/claude--debug* reports/claude--debug* journal/claude--debug* >/dev/null 2>&1 \
    && git push -q >/dev/null 2>&1 \
    && echo "pushed → cloud-data" ) || echo "WARN: cloud-data publish failed (artifacts still on disk)"
else
  echo "skip: ~/git/cloud-data (not a git repo)"
fi

# unix mirror: flat copy the cloud Claude session can pull (it has no access
# to the cloud-data repo).
if [ -d "$HOME/git/unix/.git" ]; then
  mkdir -p "$UNIX_REPORT_DIR"
  for f in "$LOG" "$TUIBARE" "$TUIFULL" "$REPORT" "$JOURNAL"; do
    [ -f "$f" ] && cp -f "$f" "$UNIX_REPORT_DIR/" 2>/dev/null
  done
  ( cd "$HOME/git/unix" \
    && git add 1_reports/claude--debug* >/dev/null 2>&1 \
    && git commit -q -m "claude--debug $(date -u +%FT%TZ)" -- 1_reports/claude--debug* >/dev/null 2>&1 \
    && git push -q >/dev/null 2>&1 \
    && echo "pushed → unix (1_reports mirror)" ) || echo "WARN: unix mirror publish failed"
fi
echo ""
echo "done."
echo "  log     : $LOG"
echo "  report  : $REPORT"
echo "  journal : $JOURNAL"
