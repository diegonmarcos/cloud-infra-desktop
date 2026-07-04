#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Cloud Terminal — Tauri (Rust) build dispatcher                    ║
# ║                                                                    ║
# ║ Port of the Electron app to Tauri. Toolchain (rust/cargo/          ║
# ║ cargo-tauri/webkitgtk/node/magick) ALL comes from flake.nix —      ║
# ║ never assume the host has them. Every build call goes through      ║
# ║ `nix develop` (in_nix), same law as the ea_cloud-* Android apps.   ║
# ║                                                                    ║
# ║   build.sh vendor    copy xterm assets node_modules → frontend/    ║
# ║   build.sh icons     generate src-tauri/icons from src/assets      ║
# ║   build.sh build     vendor + icons + cargo tauri build (release)  ║
# ║   build.sh dev       cargo tauri dev (hot-reload)                  ║
# ║   build.sh check     cargo check (fast compile validation)         ║
# ║   build.sh fetch [id] download CI-built binary (latest green) → ci ║
# ║   build.sh run <p>   launch local/fetched binary via nix develop   ║
# ║   build.sh install   put `cloud-terminal` launcher on PATH (Tauri) ║
# ║   build.sh shell     enter the Nix devShell                       ║
# ║   build.sh clean     rm target/ dist/ frontend/vendor              ║
# ║                                                                    ║
# ║ TODO(release): ship/oras-push/gh-release/pull for the Tauri        ║
# ║   artifact (binary/AppImage) — artifact model differs from the      ║
# ║   old electron tar.zst payload; port once `build` is verified.      ║
# ║                                                                    ║
# ║ NEVER bypass this script for build operations.                     ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
TAURI="$ROOT/src-tauri"
FRONTEND="$ROOT/frontend"
DIST="$ROOT/dist"
CMD="${1:-build}"

# Cap compile parallelism — the GTK/WebKit-sys crates + linker peak hard on
# RAM; the default (one job per core) OOM-kills ld (exit 137) on 8–16 GB
# laptops. Override with CARGO_BUILD_JOBS=<n> for beefier machines / CI.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
# Drop debuginfo on the dev/check profile — debug=2 (default) is the single
# biggest rustc peak-memory driver; we don't debug the GTK-sys deps.
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"

log()    { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
errlog() { printf "\033[0;31m[%s] ERROR: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1" >&2; }

# Nix-wrapped invocation — reproducible toolchain from flake.nix.
# _nix_run <installable> <cmd…> : run a command inside a specific devShell.
#   in_nix    → full build shell   (.#default: rust + cargo-tauri + node + magick)
#   in_nix_rt → lean runtime shell (.#runtime: only the webkit/gtk runtime libs)
# `run` uses the lean shell so launching a prebuilt binary does NOT realize the
# whole build toolchain closure (that was the "thousands of compile steps").
_nix_run() {
  local shell="$1"; shift
  if [ "${BYPASS_NIX:-0}" = "1" ]; then
    "$@"
  else
    command -v nix >/dev/null 2>&1 || { errlog "nix not on PATH; install nix or set BYPASS_NIX=1"; exit 1; }
    nix develop "$shell" --command "$@"
  fi
}
in_nix()    { _nix_run "$ROOT" "$@"; }
in_nix_rt() { _nix_run "$ROOT#runtime" "$@"; }

# Do all runtime tray PNGs exist? `run` only needs them PRESENT — regenerating
# on SVG change is `build`/`install`'s job (both call icons()). This lets `run`
# stay on the lean runtime shell (magick lives in the heavy build shell).
icons_current() {
  local s png
  for s in "$SRC/assets/"*.svg; do
    [ -e "$s" ] || return 1
    png="$SRC/assets/$(basename "$s" .svg).png"
    [ -f "$png" ] || return 1
  done
  return 0
}

# ── vendor: copy xterm runtime assets into frontend/vendor (no bundler) ──
# The renderer loads these via <script>/<link>, so no node require + no build
# step for the webview. node_modules populated by `npm install` in the shell.
vendor() {
  log "vendoring xterm assets → frontend/vendor"
  in_nix npm --prefix "$ROOT" install --no-audit --no-fund --silent \
    @xterm/xterm@^6.0.0 @xterm/addon-fit@^0.11.0
  local nm="$ROOT/node_modules"
  mkdir -p "$FRONTEND/vendor"
  cp "$nm/@xterm/xterm/lib/xterm.js"            "$FRONTEND/vendor/xterm.js"
  cp "$nm/@xterm/xterm/css/xterm.css"           "$FRONTEND/vendor/xterm.css"
  cp "$nm/@xterm/addon-fit/lib/addon-fit.js"    "$FRONTEND/vendor/addon-fit.js"
  log "  → frontend/vendor/{xterm.js,xterm.css,addon-fit.js}"
}

# ── icons: tauri.conf.json expects icons/{32x32,128x128,icon}.png ──
# Generated from the primary profile SVG so we keep ONE source of truth.
icons() {
  log "generating tauri icons from src/assets"
  local svg; svg="$(ls "$SRC/assets/"*.svg 2>/dev/null | head -1)"
  [ -z "$svg" ] && { errlog "no SVG in src/assets to build icons from"; exit 1; }
  mkdir -p "$TAURI/icons"
  in_nix magick -background none "$svg" -resize 32x32   -define png:color-type=6 "PNG32:$TAURI/icons/32x32.png"
  in_nix magick -background none "$svg" -resize 128x128 -define png:color-type=6 "PNG32:$TAURI/icons/128x128.png"
  in_nix magick -background none "$svg" -resize 512x512 -define png:color-type=6 "PNG32:$TAURI/icons/icon.png"
  # Per-profile tray PNGs the app loads at runtime (CT_ASSETS_DIR).
  local s name
  for s in "$SRC/assets/"*.svg; do
    name="$(basename "$s" .svg)"
    in_nix magick -background none "$s" -resize 128x128 -define png:color-type=6 "PNG32:$SRC/assets/$name.png"
  done
}

build() {
  vendor
  icons
  log "cargo tauri build (release)"
  ( cd "$TAURI" && in_nix cargo tauri build )
  mkdir -p "$DIST"
  cp "$TAURI/target/release/cloud-terminal" "$DIST/cloud-terminal" 2>/dev/null || true
  log "→ binary: $TAURI/target/release/cloud-terminal"
  log "→ bundles: $TAURI/target/release/bundle/"
}

case "$CMD" in
  vendor) vendor ;;
  icons)  icons ;;
  build)  build ;;
  dev)    vendor; icons; ( cd "$TAURI" && in_nix cargo tauri dev ) ;;
  check)  vendor; icons; ( cd "$TAURI" && in_nix cargo check ) ;;
  fetch)
    # Pull the CI-built binary from the latest successful ship-cloud-terminal
    # run — lets a RAM-constrained box (whose watchdog kills a local compile)
    # still run the app. gh is the host tool (not in the flake).
    command -v gh >/dev/null || { errlog "gh CLI required for fetch"; exit 1; }
    rid="${2:-$(gh run list --workflow=ship-cloud-terminal.yml --limit 20 \
      --json databaseId,conclusion 2>/dev/null | jq -r 'map(select(.conclusion=="success"))[0].databaseId')}"
    [ -z "$rid" ] && { errlog "no successful CI run found"; exit 1; }
    log "fetching cloud-terminal-bundle from run $rid → dist/ci"
    rm -rf "$DIST/ci"; mkdir -p "$DIST/ci"
    gh run download "$rid" -n cloud-terminal-bundle -D "$DIST/ci"
    chmod +x "$DIST/ci/cloud-terminal" 2>/dev/null || true
    log "→ $DIST/ci/cloud-terminal"
    ;;
  run)
    # Launch a PREBUILT binary — never compiles. Uses the LEAN runtime shell
    # (.#runtime) to resolve the webkit/glibc LD_LIBRARY_PATH; the heavy build
    # toolchain (rust/cargo-tauri/node/magick) is NOT realized here.
    # Tray PNGs are only regenerated when a source SVG changed (magick needs
    # the build shell) — the common case skips it and stays lean.
    if icons_current; then
      log "tray icons up to date — skipping regeneration"
    else
      log "tray icons stale/missing — regenerating (one-time, build shell)"
      icons
    fi
    # Pick whichever binary is actually NEWER — a local release build and a
    # fetched CI build can both exist, and blindly preferring one (the old
    # behavior always preferred local) silently launches stale code whenever
    # the other was rebuilt more recently. This bit a real session: a local
    # build from hours earlier kept shadowing every subsequent CI fetch.
    local_bin="$TAURI/target/release/cloud-terminal"
    ci_bin="$DIST/ci/cloud-terminal"
    bin=""
    if [ -x "$local_bin" ] && [ -x "$ci_bin" ]; then
      if [ "$local_bin" -nt "$ci_bin" ]; then bin="$local_bin"; log "using LOCAL build (newer than fetched CI binary)"
      else bin="$ci_bin"; log "using FETCHED CI build (newer than local build)"; fi
    elif [ -x "$local_bin" ]; then bin="$local_bin"
    elif [ -x "$ci_bin" ]; then bin="$ci_bin"
    fi
    # Auto-fetch the CI binary if none present (first run on a fresh machine).
    [ -x "$bin" ] || { log "no binary — fetching latest CI build…"; "$ROOT/build.sh" fetch && bin="$ci_bin"; }
    [ -x "$bin" ] || { errlog "no binary — 'build.sh build' or 'build.sh fetch' first"; exit 1; }
    # Resolve the runtime lib path (glibc + webkit) — CACHED, so a normal
    # launch is just resolve-cache + exec, like any other app. Every previous
    # version called `nix develop` on EVERY launch just to read one env var
    # (flake realize + shellHook + shell spawn — the ~29s "resolving runtime
    # libs" delay). Now: resolve once via the lean shell (guarantees the
    # store paths are realized), cache the string to disk, and skip Nix
    # entirely on every later launch. Cache invalidates when flake.nix/
    # flake.lock change (a new/updated dependency needs re-resolving).
    ldpcache="$DIST/.runtime-ldpath"
    stale=1
    if [ -f "$ldpcache" ] && [ -s "$ldpcache" ]; then
      stale=0
      for f in "$ROOT/flake.nix" "$ROOT/flake.lock"; do
        [ "$f" -nt "$ldpcache" ] && stale=1
      done
      # A GC (or a daemon-crash cleanup, or `nix store gc` run for any other
      # reason) can remove a store path the cache still references even
      # though flake.nix/flake.lock never changed — this silently broke
      # every launch with NO error surfaced (stdout/stderr only go to
      # dist/run.log, which nothing was watching): the binary died instantly
      # with "error while loading shared libraries", no window ever opened.
      # Re-verify every cached path still exists before trusting the cache.
      if [ "$stale" = "0" ]; then
        IFS=':' read -ra _cached_parts <<< "$(cat "$ldpcache")"
        for p in "${_cached_parts[@]}"; do
          [ -d "$p" ] || { stale=1; log "cached runtime lib path vanished (GC'd?) — re-resolving: $p"; break; }
        done
      fi
    fi
    if [ "$stale" = "0" ]; then
      ldp="$(cat "$ldpcache")"
    else
      mkdir -p "$DIST"
      # FAST path: `runtimeLibPath` is a plain evaluated string (pkgs.lib.
      # makeLibraryPath), not a devShell — `nix eval --raw` resolves it with
      # no shell spawn AND no stdenv/-dev-output pull (mkShell always wires in
      # every package's `.dev` output for pkg-config, which is what made even
      # the "lean" devShell slow: gcc/binutils/patchelf/webkitgtk-dev/gtk+3-dev
      # etc., none of which are needed just to set one env var).
      log "resolving runtime libs (fast path: nix eval, no dev outputs)…"
      # flake-utils.eachDefaultSystem nests every output per-system
      # (runtimeLibPath.<system> = "..."), so the attr path needs the actual
      # system — resolve it dynamically rather than assuming x86_64-linux.
      _sys="$(nix eval --impure --raw --expr 'builtins.currentSystem' \
        --extra-experimental-features "nix-command flakes" 2>/dev/null)"
      ldp="$(nix eval --raw "$ROOT#runtimeLibPath.$_sys" --accept-flake-config \
        --extra-experimental-features "nix-command flakes" 2>/dev/null)"
      # Verify every resolved path actually exists on disk — nix eval doesn't
      # realize anything, so a bare machine (or post-GC store) can eval a
      # path that was never built/fetched.
      ok=1
      if [ -n "$ldp" ]; then
        IFS=':' read -ra _parts <<< "$ldp"
        for p in "${_parts[@]}"; do [ -d "$p" ] || { ok=0; break; }; done
      else
        ok=0
      fi
      if [ "$ok" = "0" ]; then
        log "fast path missed (store incomplete) — falling back to full realize (one-time)…"
        ldp="$(in_nix_rt sh -c 'printf %s "$LD_LIBRARY_PATH"')"
      fi
      [ -n "$ldp" ] && printf '%s' "$ldp" > "$ldpcache"
    fi
    [ -z "$ldp" ] && { errlog "could not resolve LD_LIBRARY_PATH from flake"; exit 1; }
    # setsid detaches into its own session (own process group + no controlling
    # tty) so the launching shell's Ctrl-C (SIGINT to ITS foreground group)
    # never reaches this process — a GUI app has no business dying with the
    # terminal that happened to start it. Backgrounded (&) + disown so the
    # shell returns immediately instead of blocking until the GUI exits.
    runlog="$DIST/run.log"
    log "launching $bin (profile ${2:-home}, multi-tray) in user env — detached, log: $runlog"
    setsid env LD_LIBRARY_PATH="$ldp" \
      CT_APP_DIR="$SRC" CT_ASSETS_DIR="$SRC/assets" CT_PROFILES_DIR="$SRC/data" \
      CT_PROFILE="${2:-home}" CT_MULTI=1 CT_SHELL=fish \
      WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 GDK_BACKEND=wayland,x11 \
      "$bin" "${2:-home}" --show >"$runlog" 2>&1 < /dev/null &
    launched_pid=$!
    disown
    # A dynamic-linker failure (e.g. a GC'd runtime lib) kills the process in
    # milliseconds with zero visible symptom otherwise — the shell returns
    # "success" immediately (setsid backgrounded it) and the failure sits
    # silently in run.log. Give it a beat, then check it's actually alive.
    sleep 0.3
    if ! kill -0 "$launched_pid" 2>/dev/null; then
      errlog "launch failed immediately — see $runlog:"
      cat "$runlog" >&2
      exit 1
    fi
    log "detached (pid $launched_pid) — terminal is free"
    ;;
  install)
    # Put a single `cloud-terminal` launcher on PATH that opens the Tauri app
    # (all profile trays via CT_MULTI, through `build.sh run`), and remove the
    # stale per-profile ELECTRON launchers this replaces.
    bindir="$HOME/.local/bin"; mkdir -p "$bindir"
    rm -f "$bindir/cloud-terminal-cloud" "$bindir/cloud-terminal-nix-flakes" "$bindir/cloud-terminal-tools"
    cat > "$bindir/cloud-terminal" <<LAUNCH
#!/usr/bin/env bash
# Cloud Terminal (Tauri) launcher — generated by build.sh install.
exec bash "$ROOT/build.sh" run "\$@"
LAUNCH
    chmod +x "$bindir/cloud-terminal"
    log "→ $bindir/cloud-terminal (opens the Tauri terminal)"
    log "removed stale electron launchers: cloud-terminal-{cloud,nix-flakes,tools}"
    ;;
  shell)  exec nix develop "$ROOT" ;;
  clean)  rm -rf "$TAURI/target" "$DIST" "$FRONTEND/vendor" "$ROOT/node_modules"; log "cleaned" ;;
  *)      errlog "unknown command: $CMD"; exit 1 ;;
esac
