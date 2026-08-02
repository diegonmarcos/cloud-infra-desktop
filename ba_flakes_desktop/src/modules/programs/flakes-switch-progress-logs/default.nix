# programs/flakes-switch-progress-logs/default.nix — installs
# `flakes-switch-progress-logs` (canonical name) and its compat alias
# `nix-switch-progress-wrap`, a transparent wrapper around any nix command
# build.sh runs. Shows exactly ONE window: a Konsole tailing a live,
# ANSI-colored, fully copyable status log — repo clean/dirty check, commit
# being applied vs the previously applied one (+ diffstat), closure size, a
# live PSI (/proc/pressure) panel with a spinner, a data-dense two-bar
# progress line (overall % + current-step %, byte sizes, elapsed/remaining/
# total ETA — see progress.mjs), and the real build/activation output —
# split into three self-detected phases (Preparing / Building & Copying /
# Activating), so `activate` is always its own visible step regardless of
# whether build.sh did a full local eval+build or a `pull` (fetch + activate
# only).
#
# The Konsole window is NEVER auto-closed — on success/failure it gets a
# final banner in the log plus a non-blocking notify-send toast; on failure
# the full (de-ANSI'd) log is copied to the clipboard automatically. Nothing
# blocks waiting for user interaction.
#
# History: designed as nix-switch-progress.mjs + .json (2026-06-20), enriched
# 2026-07-04, then collapsed from three windows (2 kdialog progress bars +
# Konsole) down to this single Konsole window per direct request — the two
# kdialog bars were data-poor (bare % + one-line label) versus the rich data
# already flowing through the Konsole log, so the fix was to put ALL progress
# data (both bars, sizes, ETA) into that one log stream instead of splitting
# it across three separate windows. Moved into this directory and renamed
# nix-switch-progress-wrap -> flakes-switch-progress-logs (2026-08-02) when
# build.sh grew a global re-exec that wraps EVERY invocation (not just the
# nix/home-manager calls this originally targeted) — see the owner/nested
# split below, and the compat alias's own comment for why the old name is
# still installed too.
# Always-on (same pattern as programs/dev-shell.nix). All labels/colors/
# spinner frames/refresh interval are data-driven from config.json —
# nothing hardcoded here or in progress.mjs. Passthrough (no window at all)
# when there's no graphical session or konsole is missing — must never
# block a headless/CI/SSH nix invocation.
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./config.json);
  mjs = ./progress.mjs;
  col = name: cfg.colors.${name};
  spinnerBash = "(" + lib.concatMapStringsSep " " (f: "\"${f}\"") cfg.spinner_frames + ")";

  # Bound once, installed under BOTH names below — identical text, so the
  # two entry points can never drift out of sync with each other.
  wrapperScript = ''
      #!/usr/bin/env bash
      # Generated from programs/flakes-switch-progress-logs/default.nix — do
      # not edit by hand.
      set -uo pipefail

      # ── Nested mode: NSP_ACTIVE was already set when we started, so an
      #    outer flakes-switch-progress-logs invocation already owns the ONE
      #    window (build.sh's own global re-exec at the bottom of build.sh,
      #    or a bare direct invocation reached through the cross-repo
      #    nix-command-catcher shim). We are one of that outer command's own
      #    internal nix/home-manager calls (nix_switch()'s wrap, the pull
      #    path's wrap, or a nested `nix`/`nixos-rebuild` call reached
      #    through the catcher shim) — open NOTHING (no window, no header, no
      #    PSI loop, no final banner, no notify-send). Just feed the SAME
      #    status file the owner is already tailing, so byte-level nix build
      #    bars still show up — inside the one already-open window instead of
      #    opening a second one.
      if [ -n "''${NSP_ACTIVE:-}" ]; then
        case "$1" in
          nix|home-manager) set -- "$@" --log-format internal-json ;;
        esac
        if [ -n "''${NSP_STATUS_FILE:-}" ] && [ -w "''${NSP_STATUS_FILE}" ]; then
          set -o pipefail
          "$@" 2>&1 | node "${mjs}" | tee -a "$NSP_STATUS_FILE" >/dev/null
          exit "''${PIPESTATUS[0]}"
        fi
        exec "$@"
      fi

      # ── Owner mode (NSP_ACTIVE unset on entry — the outermost invocation):
      #    exactly the original single-window behaviour below. ─────────────

      # Composability with the global nix/nixos-rebuild PATH shim
      # (aa_desk-usr configuration_nix-command-catcher.nix, 2026-07-26): that
      # shim shadows `nix`/`nixos-rebuild` and routes heavy verbs through THIS
      # wrapper. Mark this whole process tree as already inside the catcher so
      # any inner `nix`/`nixos-rebuild` call — the shim's own recursive call,
      # or build.sh's own nix_switch()/pull re-wrap — takes the nested-mode
      # branch above instead of opening a SECOND progress window / recursing.
      export NSP_ACTIVE=1

      # Passthrough (no popup/window) when there's no graphical session or
      # konsole is missing — must never block a headless/CI/SSH nix
      # invocation. This runs before any state is created, so owner mode
      # costs nothing extra over a bare `exec "$@"` on SSH/CI/headless.
      if { [ -z "''${DISPLAY:-}" ] && [ -z "''${WAYLAND_DISPLAY:-}" ]; } || ! command -v konsole >/dev/null 2>&1; then
        exec "$@"
      fi

      C_BANNER='\033[${col "banner"}m'; C_OK='\033[${col "ok"}m'; C_FAIL='\033[${col "fail"}m'
      C_DIM='\033[${col "dim"}m'; C_WARN='\033[${col "warn"}m'; C_VAL='\033[${col "value"}m'; C_0='\033[0m'

      STATE_DIR="$HOME/.cache/nix-switch-progress"
      mkdir -p "$STATE_DIR"
      LAST_COMMIT_FILE="$STATE_DIR/last-commit"
      STATUS_FILE="$(mktemp --tmpdir nsp-status.XXXXXX)"
      # Nested invocations (see the branch above) tail into this SAME file
      # instead of opening their own window.
      export NSP_STATUS_FILE="$STATUS_FILE"
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
      # progress.mjs) — so the one Konsole window still shows everything,
      # just without the byte-level nix build bars (there's nothing to bar
      # there — no local build/copy happens on that path). Owner mode reaches
      # this when it IS the wrapped command (e.g. run directly via the
      # nix-command-catcher shim); the nested-mode branch above has its own
      # copy of this same case statement for when it isn't.
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
        _clean="$(sed -r 's/\x1b\[[0-9;]*m//g' "$STATUS_FILE")"
        if command -v wl-copy >/dev/null 2>&1; then
          printf '%s' "$_clean" | wl-copy
        elif command -v xclip >/dev/null 2>&1; then
          printf '%s' "$_clean" | xclip -selection clipboard
        fi
        # STATUS_FILE must survive past this script's exit so the "Open Log"
        # notification action (below) has something to open — copy it into a
        # stable per-failure path instead of leaving it in mktemp limbo.
        FAIL_LOG="$STATE_DIR/last-failure.log"
        cp -f "$STATUS_FILE" "$FAIL_LOG" 2>/dev/null || true
        ${lib.optionalString cfg.notify_on_finish ''
        if command -v notify-send >/dev/null 2>&1; then
          _action="$(notify-send -u critical -i "${cfg.icon}" -A "open=Open Log" "${cfg.title}" "Failed (exit $_rc) — full log copied to clipboard." 2>/dev/null || true)"
          if [ "$_action" = "open" ]; then
            konsole -e less -R "$FAIL_LOG" >/dev/null 2>&1 &
          fi
        fi
        ''}
      fi

      exit "$_rc"
    '';
in {
  home.file.".local/bin/flakes-switch-progress-logs" = {
    executable = true;
    text = wrapperScript;
  };

  # Compat alias — NOT optional, do not drop. aa_desk-usr_x86_surface-linux_
  # nixos's src/modules/configuration_nix-command-catcher.nix (a NixOS SYSTEM
  # module in a DIFFERENT repo) PATH-shims `nix`/`nixos-rebuild` through the
  # wrapper by this EXACT name. Removing this file would silently degrade
  # that shim to plain passthrough until a full NixOS rebuild picks up a
  # renamed reference there too.
  home.file.".local/bin/nix-switch-progress-wrap" = {
    executable = true;
    text = wrapperScript;
  };
}
