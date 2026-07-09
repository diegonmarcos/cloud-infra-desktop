# programs/nix-switch-progress.nix — installs `nix-switch-progress-wrap`, a
# transparent wrapper around any nix command build.sh runs. Shows exactly
# ONE window: a Konsole tailing a live, ANSI-colored, fully copyable status
# log — repo clean/dirty check, commit being applied vs the previously
# applied one (+ diffstat), closure size, a live PSI (/proc/pressure) panel
# with a spinner, a data-dense two-bar progress line (overall % + current-
# step %, byte sizes, elapsed/remaining/total ETA — see nix-switch-progress.mjs),
# and the real build/activation output — split into three self-detected
# phases (Preparing / Building & Copying / Activating), so `activate` is
# always its own visible step regardless of whether build.sh did a full
# local eval+build or a `pull` (fetch + activate only).
#
# The Konsole window is NEVER auto-closed — on success/failure it gets a
# final banner in the log plus a non-blocking notify-send toast; on failure
# the full (de-ANSI'd) log is copied to the clipboard automatically. Nothing
# blocks waiting for user interaction.
#
# Was designed (nix-switch-progress.mjs + .json, 2026-06-20), enriched
# 2026-07-04, then collapsed from three windows (2 kdialog progress bars +
# Konsole) down to this single Konsole window per direct request — the two
# kdialog bars were data-poor (bare % + one-line label) versus the rich data
# already flowing through the Konsole log, so the fix was to put ALL progress
# data (both bars, sizes, ETA) into that one log stream instead of splitting
# it across three separate windows.
# Always-on (same pattern as programs/dev-shell.nix). All labels/colors/
# spinner frames/refresh interval are data-driven from nix-switch-progress.json
# — nothing hardcoded here or in the .mjs. Passthrough (no window at all)
# when there's no graphical session or konsole is missing — must never
# block a headless/CI/SSH nix invocation.
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./nix-switch-progress.json);
  mjs = ./nix-switch-progress.mjs;
  col = name: cfg.colors.${name};
  spinnerBash = "(" + lib.concatMapStringsSep " " (f: "\"${f}\"") cfg.spinner_frames + ")";
in {
  home.file.".local/bin/nix-switch-progress-wrap" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generated from programs/nix-switch-progress.nix — do not edit by hand.
      set -uo pipefail

      # Passthrough (no popup/window) when there's no graphical session or
      # konsole is missing — must never block a headless/CI/SSH nix invocation.
      if { [ -z "''${DISPLAY:-}" ] && [ -z "''${WAYLAND_DISPLAY:-}" ]; } || ! command -v konsole >/dev/null 2>&1; then
        exec "$@"
      fi

      C_BANNER='\033[${col "banner"}m'; C_OK='\033[${col "ok"}m'; C_FAIL='\033[${col "fail"}m'
      C_DIM='\033[${col "dim"}m'; C_WARN='\033[${col "warn"}m'; C_VAL='\033[${col "value"}m'; C_0='\033[0m'

      STATE_DIR="$HOME/.cache/nix-switch-progress"
      mkdir -p "$STATE_DIR"
      LAST_COMMIT_FILE="$STATE_DIR/last-commit"
      STATUS_FILE="$(mktemp --tmpdir nsp-status.XXXXXX)"
      START_MS=$(( $(date +%s%N) / 1000000 ))

      # ── Repo state: clean/dirty, commit being applied vs the previously
      #    applied one (recorded by THIS wrapper on its last success), diffstat.
      SRC_DIR="''${NSP_SRC_DIR:-}"
      DIRTY="" CUR_HASH="" CUR_SUBJ="" PREV_HASH="" PREV_SUBJ="" DIFFSTAT=""
      if [ -n "$SRC_DIR" ] && git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        DIRTY="$(git -C "$SRC_DIR" status --porcelain)"
        CUR_HASH="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null)"
        CUR_SUBJ="$(git -C "$SRC_DIR" log -1 --format=%s 2>/dev/null)"
        PREV_HASH="$(cat "$LAST_COMMIT_FILE" 2>/dev/null || true)"
        if [ -n "$PREV_HASH" ] && git -C "$SRC_DIR" cat-file -e "$PREV_HASH" 2>/dev/null; then
          PREV_SUBJ="$(git -C "$SRC_DIR" log -1 --format=%s "$PREV_HASH" 2>/dev/null)"
          DIFFSTAT="$(git -C "$SRC_DIR" diff --stat "$PREV_HASH"..HEAD 2>/dev/null | tail -1)"
        fi
      fi

      # ── Closure/tarball size — best-effort, computed in the background
      #    (nix path-info -S can take a few seconds) and appended when ready.
      if [ -n "''${NSP_FLAKE_ATTR:-}" ]; then
        (
          _sz="$(nix path-info -S "$NSP_FLAKE_ATTR" 2>/dev/null | awk '{print $2}')"
          if [ -n "$_sz" ]; then
            _human="$(numfmt --to=iec "$_sz" 2>/dev/null || echo "$_sz bytes")"
            printf '\n%bClosure size:%b %s\n' "$C_VAL" "$C_0" "$_human" >> "$STATUS_FILE"
          fi
        ) &
      fi

      # ── Header ────────────────────────────────────────────────────────
      {
        printf '%b╔══════════════════════════════════════════════════════════╗%b\n' "$C_BANNER" "$C_0"
        printf '%b║              ${cfg.title}                    ║%b\n' "$C_BANNER" "$C_0"
        printf '%b╚══════════════════════════════════════════════════════════╝%b\n' "$C_BANNER" "$C_0"
        echo ""
        if [ -n "$SRC_DIR" ]; then
          printf 'Repo:      %b%s%b\n' "$C_VAL" "$(basename "$SRC_DIR")" "$C_0"
          if [ -z "$DIRTY" ]; then
            printf 'Status:    %b✓ clean%b\n' "$C_OK" "$C_0"
          else
            printf 'Status:    %b✗ %s dirty file(s)%b\n' "$C_FAIL" "$(echo "$DIRTY" | wc -l)" "$C_0"
            echo "$DIRTY" | sed 's/^/             /'
          fi
          printf 'Commit:    %b%s%b  %s\n' "$C_VAL" "$CUR_HASH" "$C_0" "$CUR_SUBJ"
          [ -n "$PREV_HASH" ] && printf 'Previous:  %b%s%b  %s\n' "$C_VAL" "$PREV_HASH" "$C_0" "$PREV_SUBJ"
          [ -n "$DIFFSTAT" ] && printf 'Diff:      %s\n' "$DIFFSTAT"
        fi
        printf 'Closure:   (calculating…)\n'
        echo ""
        printf '%b▶▶▶ PHASE: Preparing%b\n' "$C_WARN" "$C_0"
      } > "$STATUS_FILE"

      # ── PSI (/proc/pressure) panel — relative avg10/60/300 % AND absolute
      #    cumulative stall µs (both in the raw kernel line), refreshed on an
      #    interval with a rotating spinner. Killed in the EXIT trap. ──────
      SPINNER=${spinnerBash}
      _psi_loop() {
        local i=0
        while :; do
          local f="''${SPINNER[$((i % ''${#SPINNER[@]}))]}"
          {
            echo ""
            printf '%b── PSI %s %s ──%b\n' "$C_DIM" "$f" "$(date +%H:%M:%S)" "$C_0"
            for r in cpu memory io; do
              [ -r "/proc/pressure/$r" ] && awk -v r="$r" '{print "  " r " " $0}' "/proc/pressure/$r"
            done
          } >> "$STATUS_FILE"
          i=$((i + 1))
          sleep "${toString cfg.psi_refresh_seconds}"
        done
      }
      _psi_loop &
      PSI_PID=$!
      export NSP_CAP="${toString cfg.cap_pct_until_done}"

      trap 'kill "$PSI_PID" 2>/dev/null || true' EXIT

      # ── Companion copyable window — plain terminal text selection, never
      #    auto-closed. Geometry/title data-driven from the json config. ──
      konsole --geometry "${cfg.konsole_geometry}" -p "tabtitle=${cfg.title}" \
        -e bash -c "tail -n +1 -f '$STATUS_FILE'" >/dev/null 2>&1 &

      # --log-format internal-json is only understood by `nix build ...` and
      # `home-manager switch ...` (which wraps nix build internally) — only
      # append it when the wrapped command actually IS one of those. Other
      # callers (e.g. build.sh's `pull`/`switch` runner path: `gh run
      # download`, `zstd`, `docker`, `nix-store --import`, the activation
      # script itself) don't accept the flag at all — appending it
      # unconditionally would break them outright. Those commands' plain-text
      # output still flows through the same pipe into the .mjs, which already
      # treats any non-`@nix` line as pass-through activation output (see
      # nix-switch-progress.mjs) — so the one Konsole window still shows
      # everything, just without the byte-level nix build bars (there's
      # nothing to bar there — no local build/copy happens on that path).
      case "$1" in
        nix|home-manager) set -- "$@" --log-format internal-json ;;
      esac
      # The .mjs prints a colorized, phase-aware, data-dense progress line
      # per update (both bars, sizes, ETA — plus passes through real
      # activation output) to its own stdout — teed into BOTH the caller's
      # log file (if any) and our STATUS_FILE for the one Konsole window.
      set -o pipefail
      export NSP_START_MS="$START_MS"
      if [ -n "''${NSP_LOG_FILE:-}" ]; then
        "$@" 2>&1 | tee -a "$NSP_LOG_FILE" | node "${mjs}" | tee -a "$STATUS_FILE" >/dev/null
      else
        "$@" 2>&1 | node "${mjs}" | tee -a "$STATUS_FILE" >/dev/null
      fi
      _rc=''${PIPESTATUS[0]}

      _elapsed_s=$(( ( $(date +%s%N) / 1000000 - START_MS ) / 1000 ))

      if [ "$_rc" -eq 0 ]; then
        echo "$CUR_HASH" > "$LAST_COMMIT_FILE"
        {
          echo ""
          printf '%b✓ SWITCH SUCCEEDED%b  (total %ss)\n' "$C_OK" "$C_0" "$_elapsed_s"
        } >> "$STATUS_FILE"
        ${lib.optionalString cfg.notify_on_finish ''
        command -v notify-send >/dev/null 2>&1 && notify-send -i "${cfg.icon}" "${cfg.title}" "Completed successfully in ''${_elapsed_s}s." || true
        ''}
      else
        {
          echo ""
          printf '%b✗ SWITCH FAILED%b (exit %s)\n' "$C_FAIL" "$C_0" "$_rc"
        } >> "$STATUS_FILE"
        ${lib.optionalString cfg.notify_on_finish ''
        command -v notify-send >/dev/null 2>&1 && notify-send -u critical -i "${cfg.icon}" "${cfg.title}" "Failed (exit $_rc) — full log copied to clipboard." || true
        ''}
        _clean="$(sed -r 's/\x1b\[[0-9;]*m//g' "$STATUS_FILE")"
        if command -v wl-copy >/dev/null 2>&1; then
          printf '%s' "$_clean" | wl-copy
        elif command -v xclip >/dev/null 2>&1; then
          printf '%s' "$_clean" | xclip -selection clipboard
        fi
      fi

      exit "$_rc"
    '';
  };
}
