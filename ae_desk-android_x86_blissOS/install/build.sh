#!/usr/bin/env bash
# ae_desk-android_x86_blissOS — install BlissOS x86_64 to a folder on p5 (no repartition).
#
# Data-driven from ../blissos.json. NOTHING hardcoded: the release URL/hash, the target
# dir, the files to extract and the data.img size all come from blissos.json. The engine
# only wraps: lock (pin sha256), install (verify + extract into /blissos + make data.img),
# status, uninstall. The BOOT ENTRY is owned by aa_bootloader/src/boot.json — after install
# run `(cd ../../aa_bootloader && ./build.sh deploy)` to render+install it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/blissos.json"
SUDO="/run/wrappers/bin/sudo"; [ -x "$SUDO" ] || SUDO="sudo"

c_g='\033[0;32m'; c_y='\033[0;33m'; c_r='\033[0;31m'; c_0='\033[0m'
log()  { printf "${c_g}[blissOS]${c_0} %s\n" "$*"; }
warn() { printf "${c_y}[blissOS]${c_0} %s\n" "$*"; }
die()  { printf "${c_r}[blissOS] ERROR:${c_0} %s\n" "$*" >&2; exit 1; }
get()  { node -e "const c=require('$CFG');const v='$1'.split('.').reduce((o,k)=>o&&o[k],c);process.stdout.write(String(v??''))"; }

require_url() { [ -n "$(get release.url)" ] || die "release.url is empty in blissos.json — set it to a BlissOS x86_64 .iso asset first"; }

# lock — prefetch the release + record its SRI sha256 into blissos.json (reproducible pin).
cmd_lock() {
  require_url
  local url sha; url="$(get release.url)"
  log "prefetching $url (this downloads the ISO once to pin its sha256)…"
  sha="$(nix store prefetch-file --json "$url" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(JSON.parse(d).hash))')"
  [ -n "$sha" ] || die "prefetch failed"
  node -e "const fs=require('fs');const o=JSON.parse(fs.readFileSync('$CFG'));o.release.sha256='$sha';fs.writeFileSync('$CFG',JSON.stringify(o,null,2)+'\n');"
  log "pinned release.sha256 = $sha"
}

# fetch the ISO into the nix store by its pinned hash (verifies integrity), print its path.
fetch_iso() {
  require_url
  local url sha; url="$(get release.url)"; sha="$(get release.sha256)"
  [ -n "$sha" ] || die "release.sha256 empty — run: ./install/build.sh lock"
  nix store prefetch-file --json --hash-type sha256 --expected-hash "$sha" "$url" \
    | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(JSON.parse(d).storePath))'
}

# install — extract the live payload (kernel/initrd/ramdisk/system.sfs) into src_dir on p5,
# then create the persistent data.img. Idempotent: re-running refreshes the payload files.
cmd_install() {
  local iso dst subdir mp
  dst="$(get install.src_dir)"; mp="$(get install.mount_point)"; subdir="$(get install.iso_payload_subdir)"
  mountpoint -q "$mp" || die "$mp is not mounted (p5 Shared-Lib) — cannot install there"
  iso="$(fetch_iso)"; [ -f "$iso" ] || die "ISO not in store after fetch"
  log "verified ISO: $iso"

  local tmp; tmp="$(mktemp -d)"; trap 'fusermount -u "$tmp" 2>/dev/null || $SUDO umount "$tmp" 2>/dev/null || true; rmdir "$tmp" 2>/dev/null || true' EXIT
  # mount the ISO read-only (loop) to copy the payload out
  $SUDO mount -o loop,ro "$iso" "$tmp" 2>/dev/null || die "cannot loop-mount ISO"
  local payload="$tmp"; [ -n "$subdir" ] && payload="$tmp/$subdir"

  $SUDO mkdir -p "$dst"
  local n f; n="$(node -e "process.stdout.write(String(require('$CFG').install.files.length))")"
  for ((i=0;i<n;i++)); do
    f="$(node -e "process.stdout.write(require('$CFG').install.files[$i])")"
    [ -f "$payload/$f" ] || die "release payload missing '$f' under $payload (check install.iso_payload_subdir)"
    log "  copying $f -> $dst/$f"
    $SUDO cp -f "$payload/$f" "$dst/$f"
  done

  # persistent /data image (created once; kept across reinstalls)
  local dimg="$dst/data.img" mb; mb="$(get install.data_img_size_mb)"
  if [ ! -f "$dimg" ]; then
    log "creating data.img (${mb} MB, ext4)…"
    $SUDO dd if=/dev/zero of="$dimg" bs=1M count=0 seek="$mb" status=none
    $SUDO mkfs.ext4 -q -F "$dimg"
  else
    log "data.img already present — keeping (delete manually to reset Android data)"
  fi
  log "installed BlissOS payload into $dst"
  log "NEXT: render+deploy the boot entry:  (cd $ROOT/../aa_bootloader && ./build.sh deploy)"
}

# fetch-apks — nix-prefetch every entry in the apps lock (verifying its pinned sha256) into
# apk_dir. Reproducible + offline-verified: a tampered/moved APK fails the hash and aborts.
cmd_fetch_apks() {
  local lock dir n; lock="$ROOT/$(get apps.lock)"; dir="$ROOT/$(get apps.apk_dir)"
  [ -f "$lock" ] || die "apps lock not found: $lock"
  mkdir -p "$dir"
  n="$(node -e "process.stdout.write(String(require('$lock').apps.length))")"
  log "fetching $n APKs -> $dir (hash-verified)…"
  local i pkg url sha store
  for ((i=0;i<n;i++)); do
    pkg="$(node -e "process.stdout.write(require('$lock').apps[$i].package)")"
    url="$(node -e "process.stdout.write(require('$lock').apps[$i].url)")"
    sha="$(node -e "process.stdout.write(require('$lock').apps[$i].sha256)")"
    [ -n "$url" ] && [ -n "$sha" ] || { warn "  skip $pkg (missing url/sha256)"; continue; }
    store="$(nix store prefetch-file --json --hash-type sha256 --expected-hash "$sha" "$url" \
      | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(JSON.parse(d).storePath))')"
    [ -f "$store" ] || die "fetch failed for $pkg ($url)"
    cp -f "$store" "$dir/$pkg.apk"
    log "  ✓ $pkg"
  done
  log "fetched all APKs into $dir"
}

# provision — adb-install every fetched APK into the running BlissOS. BlissOS must be booted
# and reachable at apps.adb_target (adb over network; enable ADB in BlissOS Developer options,
# or `adb tcpip 5555` over USB first). Idempotent: -r reinstalls, keeping data.
cmd_provision() {
  local dir tgt; dir="$ROOT/$(get apps.apk_dir)"; tgt="$(get apps.adb_target)"
  command -v adb >/dev/null 2>&1 || die "adb not on PATH (add android-tools to the shell)"
  [ -d "$dir" ] || die "no fetched APKs at $dir — run: ./install/build.sh fetch-apks"
  log "adb connect $tgt…"
  adb connect "$tgt" >/dev/null 2>&1 || die "cannot adb connect $tgt (is BlissOS booted with ADB enabled?)"
  adb -s "$tgt" wait-for-device
  local apk ok=0 fail=0
  for apk in "$dir"/*.apk; do
    [ -f "$apk" ] || continue
    if adb -s "$tgt" install -r -g "$apk" >/dev/null 2>&1; then
      log "  ✓ $(basename "$apk" .apk)"; ok=$((ok+1))
    else
      warn "  ✗ $(basename "$apk" .apk) (install failed — arch/minSdk?)"; fail=$((fail+1))
    fi
  done
  log "provisioned: $ok installed, $fail failed"
}

cmd_status() {
  local dst dir; dst="$(get install.src_dir)"; dir="$ROOT/$(get apps.apk_dir)"
  echo "release: $(get release.version) [$(get release.variant)]  url=$(get release.url)"
  echo "sha256:  $(get release.sha256)"
  echo "target:  $dst"
  if [ -d "$dst" ]; then ls -lh "$dst" 2>/dev/null | sed 's/^/  /'; else echo "  (not installed)"; fi
  echo "apps:    lock=$(get apps.lock) via=$(get apps.install_via) target=$(get apps.adb_target)"
  if [ -d "$dir" ]; then echo "  fetched APKs: $(ls -1 "$dir"/*.apk 2>/dev/null | wc -l)"; else echo "  fetched APKs: 0 (run fetch-apks)"; fi
}

cmd_uninstall() {
  local dst; dst="$(get install.src_dir)"
  [ -d "$dst" ] || { log "nothing to remove at $dst"; return 0; }
  warn "removing $dst (including data.img — Android data is lost)"
  $SUDO rm -rf "$dst"
  log "removed. Also drop the boot entry: edit aa_bootloader/src/boot.json (grub.menu.blissos + linux_order + refind stanza) then ./build.sh deploy."
}

case "${1:-status}" in
  lock) cmd_lock ;;
  install) cmd_install ;;
  fetch-apks) cmd_fetch_apks ;;
  provision) cmd_provision ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  *) die "unknown command '$1' (lock|install|fetch-apks|provision|status|uninstall)" ;;
esac
