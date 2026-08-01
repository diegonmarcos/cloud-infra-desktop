#!/usr/bin/env bash
# One runnable check for the statusline's incremental token scan (the hot path
# that used to re-slurp a 62 MB transcript on every render). Asserts that
# scanning a file in two appended chunks equals scanning it whole, including
# across a multi-byte UTF-8 line — the exact case that made byte offsets drift.
#   bash test-statusline-tokscan.sh
set -u
SL="$(dirname "$0")/statusline-command.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
t="$tmp/t.jsonl"; c="$tmp/c.dat"

mk() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}},"note":"%s"}\n' "$1" "$2" "$3" "$4" "$5"; }

# The scan block, lifted verbatim from the statusline so the test tracks it.
scan() {
    transcript_path="$1"; tok_cache="$2"
    tok_off=0; sum_in=0; sum_out=0; sum_cread=0; sum_cwrite=0
    [ -f "$tok_cache" ] && read -r tok_off sum_in sum_out sum_cread sum_cwrite < "$tok_cache" 2>/dev/null
    tsize2=$(stat -c %s "$transcript_path" 2>/dev/null || echo 0)
    [ "$tsize2" -lt "${tok_off:-0}" ] && { tok_off=0; sum_in=0; sum_out=0; sum_cread=0; sum_cwrite=0; }
    if [ "$tsize2" -gt "${tok_off:-0}" ]; then
        cb=$(mktemp)
        read -r d_in d_out d_cr d_cw < <(
            tail -c "+$((tok_off + 1))" "$transcript_path" 2>/dev/null |
            LC_ALL=C gawk -v C="$cb" 'RT=="\n"{n += length($0) + 1; print} END{print n+0 > C}' |
            jq -rn 'reduce (inputs | select(.type=="assistant") | .message.usage | select(.)) as $x
                      ([0,0,0,0];
                       [ .[0] + ($x.input_tokens                // 0),
                         .[1] + ($x.output_tokens               // 0),
                         .[2] + ($x.cache_read_input_tokens     // 0),
                         .[3] + ($x.cache_creation_input_tokens // 0) ]) | @tsv' 2>/dev/null)
        consumed=$(cat "$cb"); rm -f "$cb"
        if [ -n "$consumed" ] && [ -n "${d_in:-}" ]; then
            sum_in=$((sum_in + d_in)); sum_out=$((sum_out + d_out))
            sum_cread=$((sum_cread + d_cr)); sum_cwrite=$((sum_cwrite + d_cw))
            echo "$((tok_off + consumed)) $sum_in $sum_out $sum_cread $sum_cwrite" > "$tok_cache"
        fi
    fi
    echo "$sum_in $sum_out $sum_cread $sum_cwrite"
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# ── chunk 1: includes a multi-byte line (│ ─ ✓ are all over real transcripts)
mk 10 1 100 5  "plain"      >  "$t"
mk 20 2 200 10 "5h │ Σ ✓ ─" >> "$t"
a=$(scan "$t" "$c")
[ "$a" = "30 3 300 15" ] || fail "cold scan: got '$a' want '30 3 300 15'"

# ── nothing appended: must be a no-op, not a recount
a=$(scan "$t" "$c")
[ "$a" = "30 3 300 15" ] || fail "idle rescan double-counted: got '$a'"

# ── chunk 2 appended after the multi-byte line — the offset-drift case
mk 5 4 50 1 "after ✓" >> "$t"
a=$(scan "$t" "$c")
[ "$a" = "35 7 350 16" ] || fail "incremental: got '$a' want '35 7 350 16'"

# ── a partial trailing line (still being written) must be ignored, then
#    counted in full once its newline lands
printf '{"type":"assistant","message":{"usage":{"input_tokens":99' >> "$t"
a=$(scan "$t" "$c")
[ "$a" = "35 7 350 16" ] || fail "partial line counted: got '$a'"
printf ',"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$t"
a=$(scan "$t" "$c")
[ "$a" = "134 8 350 16" ] || fail "completed line: got '$a' want '134 8 350 16'"

# ── truncation (new session reusing the path) resets instead of going negative
mk 1 1 1 1 "fresh" > "$t"; a=$(scan "$t" "$c")
[ "$a" = "1 1 1 1" ] || fail "truncation reset: got '$a' want '1 1 1 1'"

# ── the statusline itself must never slurp or spawn on the paint path.
#    Comment lines are stripped first — both patterns are named in the comments
#    that explain why they were removed.
code=$(grep -v '^[[:space:]]*#' "$SL")
printf '%s' "$code" | grep -q 'jq -rs'                 && fail "statusline still slurps the whole transcript (jq -rs)"
printf '%s' "$code" | grep -q 'my-ai usage --statusline' && fail "statusline spawns my-ai on the paint path"

echo "ok"
