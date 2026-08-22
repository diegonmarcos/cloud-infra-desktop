#!/usr/bin/env bash
# waydroid-container entrypoint — two display architectures, selected by
# WAYDROID_DISPLAY_MODE (data-driven from build.json display.mode):
#
#   native (DEFAULT — the seamless desktop UX): the HOST desktop's Wayland socket is
#   bind-mounted into this container at /host-xdg by build.sh, and Waydroid's
#   hwcomposer connects to the host compositor (KDE) DIRECTLY — Android appears as a
#   native KDE window with ONE cursor, native touch/trackpad input, native audio
#   (host pulse socket at /host-xdg/pulse/native), zero video-encode latency. This is
#   EXACTLY how bare-metal Waydroid-on-KDE works (Waydroid core concepts: hwcomposer
#   is a Wayland CLIENT of the user's compositor, the socket is bind-mounted into
#   Android's LXC container) — the Docker layer only adds lifecycle isolation, so the
#   ghost-process class of bug cannot recur (docker stop tears everything down).
#
#   stream (headless/remote fallback): a nested headless sway (wlroots, GPU-rendered
#   via WLR_RENDER_DRM_DEVICE) + Sunshine (VAAPI hardware encode → Moonlight client)
#   + wayvnc (VNC debug transport). Remote-desktop UX with its inherent tradeoffs
#   (client-side cursor, stream latency); the right mode when no host compositor
#   exists (server, remote access).
#
# All knobs are env vars set by build.sh from build.json (data-driven) — nothing here
# is hardcoded to a specific host.
set -euo pipefail

DISPLAY_MODE="${WAYDROID_DISPLAY_MODE:-native}"
VNC_PORT="${WAYDROID_VNC_PORT:-5900}"
WIDTH="${WAYDROID_WIDTH:-1920}"
HEIGHT="${WAYDROID_HEIGHT:-1080}"
HOST_WAYLAND_DISPLAY="${WAYDROID_HOST_WAYLAND_DISPLAY:-wayland-0}"

log() { printf '[waydroid-container] %s\n' "$*"; }

# ── 1) XDG_RUNTIME_DIR (also set as an image-wide ENV in the Dockerfile so every
#    `docker exec` inherits it too, not just this entrypoint's own shell) ──────────
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime}"; export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# ── 2) D-Bus: system bus (waydroid container mgmt) + session bus. The session bus
#    MUST bind to the D-Bus spec's well-known $XDG_RUNTIME_DIR/bus path — libdbus
#    auto-discovers it there with NO DBUS_SESSION_BUS_ADDRESS needed, which is what
#    lets a later, separate `docker exec waydroid app install` (run by the host, not
#    a child of this shell) actually reach the running session. ────────────────────
mkdir -p /run/dbus
# On `docker start` of an EXISTING (not freshly-created) container, /run/dbus/pid
# from a previous, ungracefully-stopped session can survive on the writable layer —
# dbus-daemon's OWN startup check (via /etc/dbus-1/system.conf's <pidfile>) then
# refuses to start, seeing an apparently-stale pidfile. Since we're the only thing
# that ever writes it, any pidfile present at OUR startup is always stale — remove
# it unconditionally before launching.
rm -f /run/dbus/pid
# --print-pid writes to a SEPARATE file of ours — NOT /run/dbus/pid, dbus-daemon's
# own conventional pidfile: pre-creating that would trip its stale-pidfile check.
dbus-daemon --system --fork --print-pid=3 3>"$XDG_RUNTIME_DIR/dbus-system-ours.pid"
dbus-daemon --session --fork --address="unix:path=$XDG_RUNTIME_DIR/bus" \
  --print-pid=3 3>"$XDG_RUNTIME_DIR/dbus-session-ours.pid"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
DBUS_SYSTEM_BUS_PID="$(cat "$XDG_RUNTIME_DIR/dbus-system-ours.pid" 2>/dev/null || true)"
DBUS_SESSION_BUS_PID="$(cat "$XDG_RUNTIME_DIR/dbus-session-ours.pid" 2>/dev/null || true)"
log "D-Bus system (pid $DBUS_SYSTEM_BUS_PID) + session (pid $DBUS_SESSION_BUS_PID) up, bus at $XDG_RUNTIME_DIR/bus"

RENDER_NODE="$(find /dev/dri -name 'renderD*' 2>/dev/null | head -1)"

if [ "$DISPLAY_MODE" = "native" ]; then
  # ── NATIVE MODE: point the waydroid session at the HOST compositor. build.sh
  #    bind-mounts the host's $XDG_RUNTIME_DIR at /host-xdg; from here on the session
  #    (and Android's hwcomposer through the LXC bind-mounts waydroid derives from
  #    these env vars) talks straight to KDE. Pulse comes along for free: waydroid's
  #    LXC config mounts $XDG_RUNTIME_DIR/pulse/native = the host's pipewire-pulse
  #    socket — native audio, no in-container pulseaudio at all. ────────────────────
  [ -S "/host-xdg/$HOST_WAYLAND_DISPLAY" ] || {
    log "FATAL: host wayland socket /host-xdg/$HOST_WAYLAND_DISPLAY not present — did build.sh mount the host XDG_RUNTIME_DIR?"
    exit 1
  }
  export XDG_RUNTIME_DIR=/host-xdg
  export WAYLAND_DISPLAY="$HOST_WAYLAND_DISPLAY"
  # Same EACCES root cause as the nested-sway iteration proved via strace: Android's
  # hwcomposer runs with an init.rc capabilities ALLOW-LIST (SYS_NICE only, no
  # CAP_DAC_OVERRIDE even at uid 0) and AF_UNIX connect() needs write permission on
  # the socket inode. The host socket is user-owned; widen the FILE mode — the host's
  # /run/user/<uid> directory stays 0700, so other host users still can't reach it.
  chmod 0777 "/host-xdg/$HOST_WAYLAND_DISPLAY" 2>/dev/null || true
  [ -S /host-xdg/pulse/native ] && chmod 0777 /host-xdg/pulse/native 2>/dev/null || true
  log "native mode: session will attach to HOST compositor ($WAYLAND_DISPLAY) — one cursor, native input/audio"
else
  # ── STREAM MODE: build the full headless stack (pulse, seatd, GPU sway, wayvnc,
  #    Sunshine). See git history for the verified design notes of each piece. ──────

  # PulseAudio — waydroid's LXC config bind-mounts $XDG_RUNTIME_DIR/pulse/native;
  # a hard mount failure aborts container start without this running first.
  pulseaudio --start --exit-idle-time=-1 --daemonize=no &
  for _ in $(seq 1 20); do [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break; sleep 0.5; done
  log "PulseAudio socket: $([ -S "$XDG_RUNTIME_DIR/pulse/native" ] && echo ready || echo MISSING)"

  # seatd — wlroots initializes libseat even fully headless.
  seatd -g video &
  SEATD_PID=$!
  for _ in $(seq 1 20); do [ -S /run/seatd.sock ] && break; sleep 0.2; done
  log "seatd up (pid $SEATD_PID): $([ -S /run/seatd.sock ] && echo ready || echo MISSING)"

  # Headless sway, GPU-rendered (WLR_RENDER_DRM_DEVICE → GLES2 on the render node,
  # not pixman software). sway refuses to run as root → dedicated sway-user; grant
  # it the render node's (host-defined) gid. Config template sets the REAL declared
  # resolution (headless backend defaults to a fixed 1280x720 otherwise) and hides
  # the compositor cursor (client cursor is the pointer in remote-desktop mode —
  # moonlight-qt#1268/Sunshine#1940).
  if [ -n "$RENDER_NODE" ]; then
    RENDER_GID="$(stat -c '%g' "$RENDER_NODE")"
    getent group "$RENDER_GID" >/dev/null || groupadd -g "$RENDER_GID" host-render
    usermod -aG "$RENDER_GID" sway-user
    log "GPU render node $RENDER_NODE (gid $RENDER_GID) granted to sway-user"
  else
    log "WARNING: no /dev/dri render node — sway will fall back to software rendering"
  fi
  sed -e "s/@WIDTH@/${WIDTH}/g" -e "s/@HEIGHT@/${HEIGHT}/g" \
    /etc/sway-waydroid.conf.tpl > /etc/sway-waydroid.conf
  chown sway-user:sway-user "$XDG_RUNTIME_DIR"
  # headless,libinput: libinput INCLUDED so Sunshine's uinput virtual input devices
  # reach the compositor (host /run/udev is mounted by build.sh for libudev discovery).
  su -s /bin/sh sway-user -c \
    "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' WLR_BACKENDS=headless,libinput WLR_LIBINPUT_NO_DEVICES=1 ${RENDER_NODE:+WLR_RENDER_DRM_DEVICE='$RENDER_NODE'} exec sway --unsupported-gpu -c /etc/sway-waydroid.conf" \
    > /var/log/sway.log 2>&1 &
  SWAY_PID=$!

  WAYLAND_SOCK=""
  for _ in $(seq 1 40); do
    WAYLAND_SOCK="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -printf '%f\n' 2>/dev/null | head -1)"
    [ -n "$WAYLAND_SOCK" ] && break
    kill -0 "$SWAY_PID" 2>/dev/null || { log "sway died — see /var/log/sway.log"; cat /var/log/sway.log; exit 1; }
    sleep 0.5
  done
  [ -n "$WAYLAND_SOCK" ] || { log "sway never created a wayland socket — see /var/log/sway.log"; cat /var/log/sway.log; exit 1; }
  export WAYLAND_DISPLAY="$WAYLAND_SOCK"
  # hwcomposer EACCES fix (init.rc capabilities allow-list strips CAP_DAC_OVERRIDE;
  # AF_UNIX connect() needs socket write permission — proven via strace).
  chmod 0777 "$XDG_RUNTIME_DIR/$WAYLAND_SOCK"
  log "sway up (pid $SWAY_PID), wayland socket $WAYLAND_DISPLAY"

  # wayvnc — VNC debug/fallback transport.
  wayvnc --output=HEADLESS-1 0.0.0.0 "$VNC_PORT" > /var/log/wayvnc.log 2>&1 &
  WAYVNC_PID=$!
  for _ in $(seq 1 20); do
    ss -tln 2>/dev/null | grep -q ":$VNC_PORT " && break
    kill -0 "$WAYVNC_PID" 2>/dev/null || { log "wayvnc died — see /var/log/wayvnc.log"; cat /var/log/wayvnc.log; exit 1; }
    sleep 0.5
  done
  log "wayvnc up (pid $WAYVNC_PID), listening VNC :$VNC_PORT"

  # Sunshine — VAAPI hardware encode of the sway output for the Moonlight client.
  # Web credentials generated once, persisted on the data volume (never in git).
  mkdir -p /var/lib/waydroid/sunshine
  SUNSHINE_PASS_FILE=/var/lib/waydroid/sunshine/web-pass
  if [ ! -f "$SUNSHINE_PASS_FILE" ]; then
    openssl rand -hex 12 > "$SUNSHINE_PASS_FILE"
    chmod 0600 "$SUNSHINE_PASS_FILE"
  fi
  sed -e "s|@RENDER_NODE@|${RENDER_NODE:-/dev/dri/renderD128}|g" \
    /etc/sunshine.conf.tpl > /etc/sunshine.conf
  sunshine /etc/sunshine.conf --creds admin "$(cat "$SUNSHINE_PASS_FILE")" \
    > /var/log/sunshine-creds.log 2>&1 || log "WARNING: sunshine --creds failed (see /var/log/sunshine-creds.log)"
  sunshine /etc/sunshine.conf > /var/log/sunshine.log 2>&1 &
  SUNSHINE_PID=$!
  for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -q ":47990 " && break
    kill -0 "$SUNSHINE_PID" 2>/dev/null || { log "WARNING: sunshine died — see /var/log/sunshine.log (VNC fallback still available)"; break; }
    sleep 0.5
  done
  log "sunshine: $(ss -tln 2>/dev/null | grep -q ':47990 ' && echo "up (pid $SUNSHINE_PID, web :47990)" || echo 'NOT LISTENING — VNC fallback only')"
fi

# ── 2c) Persist the Android USERDATA on the volume. Waydroid stores the running
#    session's Android /data (installed apps, launcher DB, settings) under the invoking
#    user's XDG data dir — here /root/.local/share/waydroid — which is the container's
#    EPHEMERAL layer, NOT the /var/lib/waydroid docker volume. Left as-is, all installed
#    apps + the seeded layout vanish on every container recreation, and `build.sh bake`
#    (which snapshots /var/lib/waydroid) captures only the vendor images, never the apps
#    — confirmed live: a baked seed restored a booting-but-empty Android. Symlink the
#    session dir onto the volume so the userdata persists AND is captured by the seed.
#    Idempotent; must run before waydroid init/session and before the seed restore (the
#    seed carries session-home as a real dir on the volume, which this symlink targets).
mkdir -p /var/lib/waydroid/session-home /root/.local/share
if [ ! -L /root/.local/share/waydroid ]; then
  rm -rf /root/.local/share/waydroid
  ln -s /var/lib/waydroid/session-home /root/.local/share/waydroid
fi

# ── 3) First-boot /data provisioning. Two paths, both keyed on an EMPTY volume
#    (no images/ yet):
#      (a) BAKED SEED (the "image baked with our configs" path): if a non-empty
#          /opt/data-seed.tar.zst is present — produced by `build.sh bake`, which
#          boots + fully provisions a scratch container and snapshots its entire
#          /var/lib/waydroid (vendor images + Android /data with all apps installed +
#          the seeded Launcher3 layout + theme + the .apps-provisioned marker) — we
#          extract it and are INSTANTLY at the provisioned state: no `waydroid init`
#          download, no per-app `pm install`, no layout pass (the marker in the seed
#          makes step 6b skip). This is what makes the FIRST launch show the curated
#          home screen immediately instead of default-then-provision.
#      (b) FALLBACK: no seed baked → `waydroid init` (fetch vendor images) now, then
#          step 6b provisions apps/layout/theme at runtime (slower first boot, but the
#          CI-built base image which cannot boot Android to bake still works).
if [ ! -d /var/lib/waydroid/images ]; then
  if [ -s /opt/data-seed.tar.zst ]; then
    log "first boot: restoring BAKED /data seed (apps+layout+theme pre-provisioned)…"
    zstd -dc /opt/data-seed.tar.zst | tar -C /var/lib/waydroid --numeric-owner -xf -
    log "  seed restored — skipping waydroid init + runtime provisioning"
  else
    log "first boot: waydroid init (fetching vendor images — this is slow, once only)…"
    waydroid init
  fi
fi

# Waydroid's OWN default LXC config mounts cgroup READ-ONLY for the guest — fine on
# bare metal, but inside Docker Android's libprocessgroup needs to CREATE its own
# cgroup subtree (/sys/fs/cgroup/uid_0) for hwcomposer/surfaceflinger. Read-only
# there is a hard, deterministic boot failure (confirmed on every fresh boot) —
# patch to rw post-init (the file is only generated by `waydroid init`).
if [ -f /var/lib/waydroid/lxc/waydroid/config ]; then
  sed -i 's/^lxc\.mount\.auto = cgroup:ro /lxc.mount.auto = cgroup:rw /' \
    /var/lib/waydroid/lxc/waydroid/config || true
fi

# ── 4) Waydroid container (Android's LXC guest) then the SESSION as a Wayland client
#    of whichever compositor $WAYLAND_DISPLAY now points at (host KDE in native mode,
#    nested sway in stream mode). ──────────────────────────────────────────────────
waydroid container start &
CONTAINER_PID=$!
for _ in $(seq 1 40); do
  waydroid status 2>/dev/null | grep -q "Session:.*STOPPED\|Session:.*RUNNING" && break
  sleep 0.5
done
log "waydroid container started"

waydroid session start &
SESSION_PID=$!
log "waydroid session start issued (WAYLAND_DISPLAY=$WAYLAND_DISPLAY, mode=$DISPLAY_MODE)"

# ── 5) Present the Android UI window. `waydroid session start` alone boots Android
#    but maps NO surface into the compositor — the UI window only appears when
#    explicitly requested via `waydroid show-full-ui` (confirmed: without it, sway's
#    window tree stayed empty while Android rendered internally). ──────────────────
for _ in $(seq 1 120); do
  waydroid status 2>/dev/null | grep -q "Session:.*RUNNING" && break
  sleep 1
done
waydroid show-full-ui &
if [ "$DISPLAY_MODE" = "stream" ]; then
  SWAYSOCK_PATH="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'sway-ipc.*.sock' | head -1)"
  UI_MAPPED=""
  for _ in $(seq 1 120); do
    if su -s /bin/sh sway-user -c "SWAYSOCK='$SWAYSOCK_PATH' swaymsg -t get_tree" 2>/dev/null \
        | grep -q '"shell": "xdg_shell"'; then
      UI_MAPPED=1; break
    fi
    sleep 1
  done
  if [ -n "$UI_MAPPED" ]; then
    log "Waydroid UI surface mapped in sway — GUI is live"
  else
    log "WARNING: Waydroid UI surface NEVER appeared in sway's tree — VNC will show a blank desktop"
  fi
else
  log "show-full-ui requested — the Waydroid window should appear on the HOST desktop (verified host-side by build.sh test)"
fi

# ── 6) Never let the display sleep — Android's screen-off timeout otherwise blanks
#    the panel after idle and the window/stream shows black (confirmed live).
#    Idempotent per boot. ────────────────────────────────────────────────────────────
BOOT_COMPLETED=""
for _ in $(seq 1 120); do
  [ "$(waydroid shell -- getprop sys.boot_completed 2>/dev/null | tr -d '[:space:]')" = "1" ] && { BOOT_COMPLETED=1; break; }
  sleep 1
done
waydroid shell -- sh -c '
  settings put system screen_off_timeout 2147483647
  svc power stayon true
  locksettings set-disabled true
  input keyevent KEYCODE_WAKEUP
  wm dismiss-keyguard
' 2>/dev/null && log "display keep-awake + lockscreen-off applied" \
  || log "WARNING: could not apply keep-awake settings (boot_completed never reached?)"
# `locksettings set-disabled true` only disables REQUIRING the keyguard on future
# locks — it does NOT dismiss one already showing (confirmed live: screencap after
# this block still showed the AOSP lockscreen clock+quick-shortcuts, not the
# provisioned home screen). `wm dismiss-keyguard` is the actual dismiss action; retry
# it once more after a short delay since the keyguard can (re)show right as
# SystemUI finishes starting, racing this first call.
sleep 2
waydroid shell -- wm dismiss-keyguard 2>/dev/null || true

# ── 6b) App provisioning — ported 2026-07-09 from the decommissioned da_waydroid-apps
#    project: install the declarative app set (build.json apps.list, APKs baked into
#    the image at /opt/apps/ by `build.sh apps-fetch`), grant permissions/app-ops, seed
#    the Launcher3 home-screen+nav layout (build.json launcher{}), and apply the theme
#    (build.json theme{}). Runs EXACTLY ONCE per container lifetime — guarded by a
#    marker on the persistent /var/lib/waydroid volume — because layout/appops writes
#    are meant to seed initial state, not fight the user's later in-app changes on
#    every restart. jq (installed in the image) reads /etc/waydroid-container.json
#    (build.json baked in by `build.sh build`). ─────────────────────────────────────
PROVISION_MARKER=/var/lib/waydroid/.apps-provisioned
CFG=/etc/waydroid-container.json
if [ ! -f "$PROVISION_MARKER" ] && [ -f "$CFG" ] && [ -n "$BOOT_COMPLETED" ]; then
  log "provisioning apps (first boot of this container's /data — one-time)…"
  # Guest /data is rbind-mounted from THIS container's own
  # /root/.local/share/waydroid/data (waydroid's own LXC config) — so staging an APK
  # for `pm install` is a plain local cp, no docker cp / cross-container step needed.
  WD_DATA=/root/.local/share/waydroid/data
  CTMP="$(jq -r '.waydroid.container_tmp' "$CFG")"
  HOST_TMP="$WD_DATA/local/tmp"
  mkdir -p "$HOST_TMP"
  GRANT_FLAG=""; [ "$(jq -r '.waydroid.grant_all_permissions' "$CFG")" = "true" ] && GRANT_FLAG="-g"

  N_APPS="$(jq -r '.apps.list | length' "$CFG")"
  i=0
  while [ "$i" -lt "$N_APPS" ]; do
    PKG="$(jq -r ".apps.list[$i].package" "$CFG")"
    APK="/opt/apps/$PKG.apk"
    if [ ! -f "$APK" ]; then
      log "  skip $PKG (no baked APK — was it in apps.list when apps-fetch ran?)"
      i=$((i + 1)); continue
    fi
    cp -f "$APK" "$HOST_TMP/$PKG.apk"
    OUT="$(waydroid shell -- pm install -r -d $GRANT_FLAG "$CTMP/$PKG.apk" 2>&1)"; OUT="${OUT//$'\r'/}"
    if ! printf '%s' "$OUT" | grep -q Success; then
      # signing-key change (e.g. a Cloud-* app re-signed by a fresh CI release) — pm
      # install -r can't replace a different signature; uninstall then fresh install.
      if printf '%s' "$OUT" | grep -qE 'signatures do not match|UPDATE_INCOMPATIBLE|INCONSISTENT_CERTIFICATES|signature'; then
        waydroid shell -- pm uninstall "$PKG" >/dev/null 2>&1 || true
        OUT="$(waydroid shell -- pm install -d $GRANT_FLAG "$CTMP/$PKG.apk" 2>&1)"; OUT="${OUT//$'\r'/}"
      fi
    fi
    rm -f "$HOST_TMP/$PKG.apk"
    if printf '%s' "$OUT" | grep -q Success; then log "  ✓ $PKG installed"; else log "  ✗ $PKG install FAILED: ${OUT##*$'\n'}"; fi

    # Declared per-app appops (build.json apps.list[].appops), plus the full_perms
    # bundle (build.json apps.full_perms_appops) for apps.list[].full_perms:true —
    # Diego's own constellation apps get every extra app-op beyond the -g runtime
    # grants above (install-other-apks, draw-over-apps, modify-settings, all-files).
    FULL="$(jq -r ".apps.list[$i].full_perms // false" "$CFG")"
    if [ "$FULL" = "true" ]; then
      jq -r '.apps.full_perms_appops[]' "$CFG" | while read -r OP; do
        waydroid shell -- appops set "$PKG" "$OP" allow >/dev/null 2>&1 \
          && log "  appop $OP=allow ($PKG, full_perms)" || true
      done
    fi
    jq -r ".apps.list[$i].appops[]? // empty" "$CFG" | while read -r OP; do
      waydroid shell -- appops set "$PKG" "$OP" allow >/dev/null 2>&1 \
        && log "  appop $OP=allow ($PKG)" || true
    done
    i=$((i + 1))
  done

  # Home-screen + nav layout (Launcher3 favorites DB). Resolve each referenced
  # package's LAUNCHER activity live (never assumed), render the layout SQL from
  # build.json's `launcher` block via gen-layout-sql.js, apply with sqlite3.
  log "resolving launcher components + applying home-screen/nav layout…"
  jq -r '
    [ (.launcher.folders | to_entries[] | select(.key | startswith("_") | not) | .value.members[]),
      (.launcher.hotseat[] | select(startswith("folder:") | not)),
      (.launcher.workspace.cells[].ref | select(startswith("folder:") | not))
    ] | unique[]
  ' "$CFG" > /tmp/launcher-pkgs.txt
  : > /tmp/components.tsv
  while read -r PKG; do
    [ -n "$PKG" ] || continue
    COMP="$(waydroid shell -- cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null \
      | tr -d '\r' | awk 'NF{l=$0} END{print l}')"
    case "$COMP" in */*) printf '%s\t%s\n' "$PKG" "$COMP" >> /tmp/components.tsv ;; esac
  done < /tmp/launcher-pkgs.txt
  COMPONENTS_J="$(jq -R -s 'split("\n") | map(select(length>0) | split("\t")) | map({(.[0]):.[1]}) | add // {}' /tmp/components.tsv)"

  DB="$(find "$WD_DATA" -path "*/$(jq -r '.waydroid.launcher_db_glob' "$CFG")" 2>/dev/null | sort | head -1)"
  if [ -n "$DB" ]; then
    FOLDERS_J="$(jq -c '.launcher.folders' "$CFG")" \
    HOTSEAT_J="$(jq -c '.launcher.hotseat' "$CFG")" \
    WORKSPACE_J="$(jq -c '.launcher.workspace' "$CFG")" \
    COMPONENTS_J="$COMPONENTS_J" \
    HOTSEAT_CONTAINER="$(jq -r '.waydroid.hotseat_container' "$CFG")" \
    WORKSPACE_CONTAINER="$(jq -r '.waydroid.workspace_container' "$CFG")" \
    FLAGS="$(jq -r '.waydroid.launch_flags' "$CFG")" \
    ITEM_APP="$(jq -r '.waydroid.item_type_application' "$CFG")" \
    ITEM_FOLDER="$(jq -r '.waydroid.item_type_folder' "$CFG")" \
    node /opt/launcher/gen-layout-sql.js > /tmp/layout.sql
    DBOWNER="$(stat -c '%u:%g' "$DB")"
    HOME_COMPONENT="$(jq -r '.waydroid.launcher_home_activity' "$CFG")"
    waydroid shell -- am force-stop "$(jq -r '.waydroid.launcher_package' "$CFG")" 2>/dev/null || true
    sqlite3 "$DB" < /tmp/layout.sql \
      && sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 \
      && rm -f "$DB-wal" "$DB-shm" \
      && chown "$DBOWNER" "$DB" \
      && log "  layout applied ($(grep -c '^INSERT' /tmp/layout.sql) rows)" \
      || log "  WARNING: layout apply failed — see $DB"
    # `-c android.intent.category.HOME` is AMBIGUOUS once apps.list installs any other
    # HOME-capable app (Cloud-SuperApp, Mako both legitimately declare it) — Android
    # then shows its disambiguation resolver ('Use Trebuchet as Home' / Just once /
    # Always), which BLOCKS rendering until manually tapped (no error, no crash — the
    # DB was correct on disk the whole time; only the resolver silently covered the
    # real home screen — confirmed live 2026-07-09). `set-home-activity` + an EXPLICIT
    # component start (`-n`, never `-c HOME`) bypasses the resolver entirely.
    waydroid shell -- cmd package set-home-activity "$HOME_COMPONENT" >/dev/null 2>&1 || true
    waydroid shell -- am start -n "$HOME_COMPONENT" >/dev/null 2>&1 || true
  else
    log "  WARNING: launcher DB not found under $WD_DATA — layout skipped"
  fi

  # Theme: dark mode, auto-rotate (follows the accelerometer HAL), wallpaper dim.
  # AOSP 13's `cmd wallpaper` has no set-image subcommand (dim controls only), so
  # `wallpaper.dim=1.0` is how a solid-black background is achieved from the host.
  if [ "$(jq -r '.theme.dark_mode' "$CFG")" = "true" ]; then
    waydroid shell -- cmd uimode night yes >/dev/null 2>&1 || true
    waydroid shell -- settings put secure ui_night_mode 2 >/dev/null 2>&1 || true
  fi
  if [ "$(jq -r '.theme.auto_rotate' "$CFG")" = "true" ]; then
    waydroid shell -- settings put system accelerometer_rotation 1 >/dev/null 2>&1 || true
  fi
  DIM="$(jq -r '.theme.wallpaper.dim' "$CFG")"
  [ -n "$DIM" ] && [ "$DIM" != "null" ] && waydroid shell -- cmd wallpaper set-dim-amount "$DIM" >/dev/null 2>&1

  # Icon/accent theme: Android 13 Material You overlay JSON (settings_secure key),
  # captured from a manually-configured session and made declarative here — see
  # build.json::theme.icon_theme. Compact (no whitespace) so the JSON survives as a
  # single argv element all the way through `waydroid shell` -> lxc-attach -> settings.
  ICON_STYLE="$(jq -r '.theme.icon_theme.theme_style // empty' "$CFG")"
  if [ -n "$ICON_STYLE" ]; then
    ICON_SRC="$(jq -r '.theme.icon_theme.color_source // "home_wallpaper"' "$CFG")"
    ICON_BOTH="$(jq -r 'if .theme.icon_theme.color_both then "1" else "0" end' "$CFG")"
    OVERLAY_JSON="$(jq -nc --arg src "$ICON_SRC" --arg style "$ICON_STYLE" --arg both "$ICON_BOTH" \
      '{"android.theme.customization.color_source":$src,"android.theme.customization.theme_style":$style,"android.theme.customization.color_both":$both}')"
    waydroid shell -- settings put secure theme_customization_overlay_packages "$OVERLAY_JSON" >/dev/null 2>&1 || true
  fi
  log "theme applied (dark_mode/auto_rotate/wallpaper/icon_theme per build.json)"

  touch "$PROVISION_MARKER"
  log "app provisioning complete — will not re-run on future restarts of this /data volume"
elif [ -f "$PROVISION_MARKER" ]; then
  log "apps already provisioned (marker present) — skipping"
elif [ -z "$BOOT_COMPLETED" ]; then
  log "skipping app provisioning — sys.boot_completed never reached 1, Android session isn't usable this boot"
fi
# The launcher force-stop/relaunch (or an idle timeout during the multi-minute
# provisioning pass) can leave/put the keyguard back up over the freshly-seeded
# home screen — dismiss it one more time so the FIRST thing shown is the
# provisioned launcher, not the lockscreen.
waydroid shell -- wm dismiss-keyguard 2>/dev/null || true

# ── 7) PID 1 duties: stay in foreground, forward SIGTERM to a FULL, ORDERED shutdown
#    of every stack this entrypoint started — graceful `waydroid ... stop` first, so
#    Android's persistent /data is never corrupted by a hard kill (the ghost-process
#    class of bug that got the original desktop-session Waydroid decommissioned). ───
term_handler() {
  log "SIGTERM received — full stack teardown…"
  waydroid session stop 2>/dev/null || true
  waydroid container stop 2>/dev/null || true
  log "  waydroid session+container stopped"
  kill "${SUNSHINE_PID:-}" 2>/dev/null || true
  wait "${SUNSHINE_PID:-}" 2>/dev/null || true
  kill "${WAYVNC_PID:-}" 2>/dev/null || true
  wait "${WAYVNC_PID:-}" 2>/dev/null || true
  kill "${SWAY_PID:-}" 2>/dev/null || true
  wait "${SWAY_PID:-}" 2>/dev/null || true
  kill "${SEATD_PID:-}" 2>/dev/null || true
  wait "${SEATD_PID:-}" 2>/dev/null || true
  pulseaudio --kill 2>/dev/null || true
  log "  display/audio stack stopped"
  [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
  [ -n "${DBUS_SYSTEM_BUS_PID:-}" ] && kill "$DBUS_SYSTEM_BUS_PID" 2>/dev/null || true
  log "  dbus stopped — teardown complete"
  exit 0
}
trap term_handler SIGTERM SIGINT

wait "$SESSION_PID" "$CONTAINER_PID" ${WAYVNC_PID:+"$WAYVNC_PID"}
