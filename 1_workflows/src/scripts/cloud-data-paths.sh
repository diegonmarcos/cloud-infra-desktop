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

cd_log()     { printf '%s/%s.log'    "$(_cd_dir logs)"    "$1"; }
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
