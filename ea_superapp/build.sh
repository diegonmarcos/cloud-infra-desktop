#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Diego Superapp — Universal Build Dispatcher                      ║
# ║                                                                  ║
# ║ Modularized monolith Android app. Single APK, gradle multi-module. ║
# ║ All toolchain (AGP, gradle, kotlin, JDK, android-sdk) comes from   ║
# ║ flake.nix — never assume host has them.                            ║
# ║                                                                  ║
# ║ Commands:                                                        ║
# ║   build       gradle assembleDebug  → dist/superapp-debug.apk     ║
# ║   release     gradle assembleRelease (signed if keystore present) ║
# ║   dev         open IDE / run on connected device (adb)            ║
# ║   test        gradle test (JVM unit tests)                        ║
# ║   instrument  gradle connectedAndroidTest (needs device)          ║
# ║   lint        gradle lint                                         ║
# ║   clean       gradle clean + rm -rf dist/                         ║
# ║   shell       enter Nix devShell (gradle + sdk + jdk)             ║
# ║   ship        build + side-load via adb (USB-connected device)    ║
# ║                                                                  ║
# ║ NEVER bypass this script for build operations.                    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
CMD="${1:-help}"

log()    { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
errlog() { printf "\033[0;31m[%s] ERROR: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1" >&2; }

# Nix-wrapped invocation: every gradle call goes through `nix develop` so the
# JDK / AGP / Android SDK are reproducible per the flake. Set BYPASS_NIX=1 to
# use host tools (only for IDE / dev — never CI).
in_nix() {
  if [ "${BYPASS_NIX:-0}" = "1" ]; then
    "$@"
  else
    command -v nix >/dev/null 2>&1 || { errlog "nix not on PATH; install nix or set BYPASS_NIX=1"; exit 1; }
    nix develop "$SCRIPT_DIR" --command "$@"
  fi
}

ensure_wrapper() {
  if [ ! -f "$SCRIPT_DIR/gradlew" ]; then
    log "gradle wrapper missing — generating via 'gradle wrapper'"
    in_nix gradle wrapper --gradle-version "$(jq -r .toolchain.gradle "$SCRIPT_DIR/build.json")"
  fi
}

step_build() {
  log "Build: superapp (debug APK)"
  ensure_wrapper
  in_nix ./gradlew :app:assembleDebug
  mkdir -p "$DIST_DIR"
  cp "$SCRIPT_DIR/app/build/outputs/apk/debug/app-debug.apk" "$DIST_DIR/superapp-debug.apk"
  log "→ $DIST_DIR/superapp-debug.apk"
}

step_release() {
  log "Build: superapp (release APK)"
  ensure_wrapper
  in_nix ./gradlew :app:assembleRelease
  mkdir -p "$DIST_DIR"
  cp "$SCRIPT_DIR/app/build/outputs/apk/release/app-release.apk" "$DIST_DIR/superapp-release.apk" 2>/dev/null \
    || cp "$SCRIPT_DIR/app/build/outputs/apk/release/app-release-unsigned.apk" "$DIST_DIR/superapp-release-unsigned.apk"
  log "→ $DIST_DIR/"
}

step_dev() {
  log "Dev: launching on connected device (adb)"
  command -v adb >/dev/null || in_nix adb devices
  in_nix ./gradlew :app:installDebug
  in_nix adb shell am start -n "com.diegonmarcos.superapp/.MainActivity"
}

step_test()       { log "Test: JVM unit tests"; ensure_wrapper; in_nix ./gradlew test; }
step_instrument() { log "Test: instrumented (needs device)"; ensure_wrapper; in_nix ./gradlew connectedAndroidTest; }
step_lint()       { log "Lint"; ensure_wrapper; in_nix ./gradlew lint; }
step_clean()      { log "Clean"; ensure_wrapper; in_nix ./gradlew clean; rm -rf "$DIST_DIR"; }
step_shell()      { log "Entering Nix devShell"; exec nix develop "$SCRIPT_DIR"; }

step_ship() {
  step_build
  log "Ship: side-loading via adb"
  in_nix adb install -r "$DIST_DIR/superapp-debug.apk"
}

case "$CMD" in
  build)      step_build ;;
  release)    step_release ;;
  dev)        step_dev ;;
  test)       step_test ;;
  instrument) step_instrument ;;
  lint)       step_lint ;;
  clean)      step_clean ;;
  shell)      step_shell ;;
  ship)       step_ship ;;
  help|*)
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# *//; /^set/d; /^$/d'
    ;;
esac
