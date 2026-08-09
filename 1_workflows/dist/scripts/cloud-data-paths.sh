# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_workflows/src/scripts/cloud-data-paths.sh
# ║   Engine : 1_workflows/src/scripts/unix-ship-repo-workflow-engine.sh
# ║   Rebuild: ./1_workflows/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# cloud-data-paths.sh — ONE output convention for every engine in the stack.
#
# Source this, then use the helpers. Never hardcode an output path again.
#
#   logs/     <name>.log     APP-SPECIFIC run logs — what one engine did on
#                            one run (build.sh switch, claude--debug, a
#                            deploy). Human-tailable, append or truncate as
#                            the engine sees fit.
#   reports/  <name>.json    PROBE RESULTS — health, security, scanning,
#                            drift, inventory. MACHINE-READABLE: something
#                            else (dashboard, MCP, CI gate) consumes these,
#                            so they are JSON, not prose.
#   journal/  <name>.text    OS-LEVEL journals — dmesg / logcat / journalctl
#                            captures. Raw system narrative, not ours.
#
# Root: $CLOUD_DATA_ROOT, else ~/git/cloud-data. If that tree is missing or
# unwritable (fresh device, cloud-data not cloned yet) every helper falls
# back to $HOME so an engine NEVER dies for lack of a log destination —
# build.sh used to abort on line 1 for exactly that reason.
#
# Usage:
#   . "$HOME/git/unix/1_workflows/dist/scripts/cloud-data-paths.sh"
#   LOG=$(cd_log bb_flakes_termux)        # …/cloud-data/logs/bb_flakes_termux.log
#   REPORT=$(cd_report claude--debug)     # …/cloud-data/reports/claude--debug.json
#   JOURNAL=$(cd_journal claude--debug)   # …/cloud-data/journal/claude--debug.text
#
# Each helper mkdir -p's its directory and prints the full path.

CLOUD_DATA_ROOT="${CLOUD_DATA_ROOT:-$HOME/git/cloud-data}"

# _cd_dir <subdir> — ensure and print the output dir, or $HOME on failure.
_cd_dir() {
  _d="$CLOUD_DATA_ROOT/$1"
  if mkdir -p "$_d" 2>/dev/null && [ -w "$_d" ]; then
    printf '%s' "$_d"
  else
    printf '%s' "$HOME"
  fi
}

# cd_log ROTATES: the switch tees full nix output (hundreds of lines, and a
# fetch list can be 150+ paths) into its log on every run, with nothing ever
# truncating it — unbounded growth on a phone that is already at 82% disk.
# One rollover file is kept (<name>.log.1), so the worst case is 2x the cap.
# Override the cap with CLOUD_DATA_LOG_MAX_KB (default 5 MB); 0 disables.
cd_log() {
  _p="$(_cd_dir logs)/$1.log"
  _cap="${CLOUD_DATA_LOG_MAX_KB:-5120}"
  if [ "$_cap" != "0" ] && [ -f "$_p" ]; then
    _sz=$(du -k "$_p" 2>/dev/null | cut -f1)
    if [ "${_sz:-0}" -gt "$_cap" ]; then
      mv -f "$_p" "$_p.1" 2>/dev/null || true
      printf '[%s] rotated: previous log exceeded %sKB, moved to %s.1\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$_cap" "$(basename "$_p")" > "$_p" 2>/dev/null || true
    fi
  fi
  printf '%s' "$_p"
}
cd_report()  { printf '%s/%s.json'   "$(_cd_dir reports)" "$1"; }
cd_journal() { printf '%s/%s.text'   "$(_cd_dir journal)" "$1"; }

# cd_report_write <name> <json> — write a report atomically (consumers may be
# reading it). Falls back to a plain write if mv across filesystems fails.
cd_report_write() {
  _p=$(cd_report "$1")
  if printf '%s\n' "$2" > "$_p.tmp" 2>/dev/null && mv "$_p.tmp" "$_p" 2>/dev/null; then
    printf '%s' "$_p"
  else
    printf '%s\n' "$2" > "$_p" 2>/dev/null || true
    printf '%s' "$_p"
  fi
}
