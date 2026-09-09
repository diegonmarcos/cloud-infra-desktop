#!/usr/bin/env bash
# ============================================================================
# cloud-ide-sshd.sh — bind-policy tester
# ----------------------------------------------------------------------------
# The one thing that must never regress: this daemon answers on wg0 and
# loopback and NOTHING ELSE. A public bind on a phone means the carrier
# network, and the dangerous form is not an explicit 0.0.0.0 — it is a config
# with no ListenAddress at all, because sshd's default is every interface.
#
# Second thing tested: the loopback-only state must be recoverable. sshd used
# to be started only when fully dead, so a start before wg0 was up produced a
# loopback-bound daemon that reported healthy forever while being unreachable
# from every mesh peer. `ensure` is what detects and rebinds that.
#
# Runs offline. Never starts a real sshd: SSHD_BIN is stubbed, so do_start
# writes the config and then fails to bring anything up, which is exactly the
# part we want to inspect.
# ============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/cloud-ide-sshd.sh"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
nope() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

echo "▶ cloud-ide-sshd bind-policy tester  ($SCRIPT)"

[ -f "$SCRIPT" ] || { nope "script missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  jq required"; exit 1; }
bash -n "$SCRIPT" && ok "bash syntax" || nope "bash syntax"

WG_IP="10.99.99.9"   # deliberately not a real address on this machine
PORT="18024"

# Sandbox: fake HOME so we never touch the real ~/.ssh.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.config/cloud-data" "$SANDBOX/bin"
# wg_ips, not just wg_ip: the phone holds one identity on several mesh
# addresses and the active WireGuard profile picks which. A v6 address is in
# here deliberately — it must survive into the config even on a host that has
# no v6 at all, for the same reason the v4 one must.
WG_IP6="fd0c:1d01::9"
printf '{"wg_ip":"%s","wg_ips":["%s","%s"],"ssh_port":%s}\n' \
  "$WG_IP" "$WG_IP" "$WG_IP6" "$PORT" \
  > "$SANDBOX/.config/cloud-data/cloud-ide-sshd.json"

# Stub sshd + ssh-keygen. keygen must actually create a file: do_start skips
# generation when the host key exists, and a missing binary would abort early.
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/sshd"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = "-f" ] && { touch "$2"; }; shift; done\nexit 0\n' \
  > "$SANDBOX/bin/ssh-keygen"
# sftp-server is never executed here — the script only interpolates its path
# into the Subsystem directive — but it is a `:?` required variable, so leaving
# it unset aborts the script at line 28 before a single line of config is
# written. That is what happened from 2026-08-25 (the commit that added the
# Subsystem directive) until 2026-09-09: EVERY phase of this tester exited at
# the first `run start`, so none of the assertions below it — including the
# allow-external-apps one this file is supposed to be guarding — had run in
# two weeks. A tester that cannot reach its own assertions reports "0 passed",
# not a failure, which is why nobody noticed.
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/sftp-server"
chmod +x "$SANDBOX/bin/sshd" "$SANDBOX/bin/ssh-keygen" "$SANDBOX/bin/sftp-server"

run() {
  HOME="$SANDBOX" XDG_CONFIG_HOME="$SANDBOX/.config" \
  CLOUD_IDE_SSHD_BIN="$SANDBOX/bin/sshd" \
  CLOUD_IDE_SSH_KEYGEN_BIN="$SANDBOX/bin/ssh-keygen" \
  CLOUD_IDE_SFTP_SERVER_BIN="$SANDBOX/bin/sftp-server" \
  bash "$SCRIPT" "$1" >/dev/null 2>&1
}
CONF="$SANDBOX/.ssh/sshd_config"

# ── Phase 1 · generated config, wg0 DOWN ─────────────────────────────────
# $WG_IP is not on any interface here, so this exercises the degraded path.
echo "▶ Phase 1 · bind policy with wg0 down"
run start
[ -f "$CONF" ] && ok "sshd_config generated" || { nope "no sshd_config written"; exit 1; }

grep -q '^ListenAddress ' "$CONF" \
  && ok "has an explicit ListenAddress (absent one = every interface)" \
  || nope "NO ListenAddress — sshd would bind every interface"

grep -q '^ListenAddress 127.0.0.1$' "$CONF" \
  && ok "binds loopback (Cloud IDE APK path survives wg0 being down)" \
  || nope "loopback listener missing"

grep -qE '^ListenAddress (0\.0\.0\.0|::|\*)' "$CONF" \
  && nope "PUBLIC BIND in generated config" \
  || ok "no public bind"

# $WG_IP is on no interface here, yet the WG line MUST still be written: the
# regression being guarded is exactly "interface not visible -> drop the
# listener", which is how a healthy tunnel got a loopback-only daemon.
grep -q "^ListenAddress $WG_IP\$" "$CONF" \
  && ok "wg0 listener written unconditionally (no interface probe)" \
  || nope "WG listener dropped — the Android netlink-blindness regression is back"

# Was "exactly two". Now every mesh address is bound, so the invariant that
# actually matters is: all of them present, plus loopback, and nothing else.
grep -q "^ListenAddress $WG_IP6\$" "$CONF" \
  && ok "v6 mesh address bound (profile-independent)" \
  || nope "v6 listener missing — a v6 profile would leave sshd loopback-only"

grep -c '^ListenAddress ' "$CONF" | grep -qx 3 \
  && ok "exactly three listeners (both mesh addrs + loopback)" \
  || nope "unexpected listener count: $(grep -c '^ListenAddress ' "$CONF")"

# The address list now comes from build.json, so a typo or a careless edit
# upstream could put 0.0.0.0 in it — and on a phone that is the carrier
# network. The script filters wildcards out rather than trusting the config;
# this is the test that makes that filter load-bearing instead of decorative.
POISON="$SANDBOX/.config/cloud-data/poisoned.json"
printf '{"wg_ip":"%s","wg_ips":["%s","0.0.0.0","::","*"],"ssh_port":%s}\n' \
  "$WG_IP" "$WG_IP" "$PORT" > "$POISON"
HOME="$SANDBOX" XDG_CONFIG_HOME="$SANDBOX/.config" \
  CLOUD_IDE_SSHD_CONFIG_JSON="$POISON" \
  CLOUD_IDE_SSHD_BIN="$SANDBOX/bin/sshd" \
  CLOUD_IDE_SSH_KEYGEN_BIN="$SANDBOX/bin/ssh-keygen" \
  CLOUD_IDE_SFTP_SERVER_BIN="$SANDBOX/bin/sftp-server" \
  bash "$SCRIPT" start >/dev/null 2>&1
if grep -qE '^ListenAddress (0\.0\.0\.0|::|\*)' "$CONF"; then
  nope "wildcard in wg_ips reached the config — PUBLIC BIND from a bad build.json"
else
  ok "wildcards in wg_ips are filtered out (config cannot open the phone up)"
fi
grep -q "^ListenAddress $WG_IP\$" "$CONF" \
  && ok "the real mesh address still survives the filter" \
  || nope "filter ate every address"

# restore the good config for anything downstream
run start

# Comments may still discuss the old probe — that history is worth keeping.
# What must not come back is an executable use of it.
grep -v '^[[:space:]]*#' "$SCRIPT" | grep -q 'ip -o addr show' \
  && nope "live code still probes the interface list" \
  || ok "no executable interface probe (comments about it are fine)"

grep -q '^PasswordAuthentication no$' "$CONF" && ok "password auth off" || nope "password auth not disabled"
grep -q '^PermitRootLogin no$'        "$CONF" && ok "root login off"    || nope "root login not disabled"

# ── Phase 2 · the regression that made the phone unreachable ─────────────
echo "▶ Phase 2 · degraded-state detection"
# Simulate: daemon alive (this shell's PID is real and killable) but its
# config carries no wg0 listener — precisely the state `start` could not fix.
mkdir -p "$SANDBOX/.cache"
echo $$ > "$SANDBOX/.cache/sshd.pid"

out=$(HOME="$SANDBOX" XDG_CONFIG_HOME="$SANDBOX/.config" CLOUD_IDE_SSHD_BIN="$SANDBOX/bin/sshd" \
      CLOUD_IDE_SSH_KEYGEN_BIN="$SANDBOX/bin/ssh-keygen" \
      CLOUD_IDE_SFTP_SERVER_BIN="$SANDBOX/bin/sftp-server" \
  CLOUD_IDE_SFTP_SERVER_BIN="$SANDBOX/bin/sftp-server" \
      bash "$SCRIPT" status 2>&1)
case "$out" in
  *"127.0.0.1 ONLY"*) ok "status reports not-accepting-on-wg0 as degraded" ;;
  *)                  nope "status hides the loopback-only state: $out" ;;
esac

grep -q 'ensure)' "$SCRIPT" && ok "ensure subcommand wired into dispatch" || nope "ensure not dispatchable"
grep -q 'do_ensure' "$SCRIPT" && ok "do_ensure defined" || nope "do_ensure missing"
grep -q 'ss -tln' "$SCRIPT" && ok "degraded check reads the socket table, not ip addr" || nope "not using ss"
grep -q 'REBIND_COOLDOWN' "$SCRIPT" && ok "rebind cooldown present (no per-shell thrash)" || nope "no cooldown"

# fish must call ensure, not start — start cannot recover a live-but-degraded
# daemon, which is the whole bug.
NIXF="$DIR/default.nix"
if grep -q 'cloud-ide-sshd ensure' "$NIXF"; then
  ok "fish shellInit calls ensure"
else
  nope "fish shellInit does not call ensure (start alone cannot rebind)"
fi

# Every other start path needs a human already holding the phone (open a
# terminal / run a switch). Without a boot hook a reboot means no wg0 SSH until
# someone physically unlocks the device.
if grep -q '.termux/boot/' "$NIXF"; then
  ok "boot hook declared (sshd comes back without a human at the phone)"
else
  nope "no ~/.termux/boot entry — a reboot leaves the phone unreachable"
fi

grep -A14 '.termux/boot/' "$NIXF" | grep -q 'cloud-ide-sshd ensure' \
  && ok "boot hook calls ensure (wg0 is usually not up yet at boot)" \
  || nope "boot hook does not call ensure"

# ── wake lock · the Doze reap ────────────────────────────────────────────
# The failure no other layer covers: Android kills proot children while the
# device idles, and every remaining start path needs a human already holding
# the phone. Three outages on 2026-08-20 came from this, not from binding.
grep -q 'acquire_wake_lock' "$SCRIPT" && ok "wake lock acquired on start" \
  || nope "no wake lock — Doze reaps the daemon and nothing restarts it"

# Best-effort is the whole point: a rejected intent must not stop sshd. A phone
# reachable until Doze beats one that refused to start over a wake lock.
grep -q 'acquire_wake_lock || true' "$SCRIPT" \
  && ok "wake lock failure cannot block startup" \
  || nope "wake lock is load-bearing for startup — an intent failure kills sshd"

# There is no termux-wake-lock binary in nix-on-droid and the intent constant
# differs between Termux and its fork, so both must be attempted. The host half
# is DERIVED from $HOME rather than typed: there are two Nix-on-Droid apps on
# this phone and a literal wakes at most one of them. The upstream com.termux.*
# constant stays literal — it names Termux proper, not this app.
grep -q '_pkg.service_wake_lock' "$SCRIPT" \
  && grep -q 'com.termux.service_wake_lock' "$SCRIPT" \
  && ok "both wake-lock intent constants attempted (this app, derived + upstream)" \
  || nope "only one intent constant tried — a wrong guess means no lock at all"

grep -q '_pkg="${HOME#/data/data/}"' "$SCRIPT" \
  && ok "wake-lock intents address the app we are actually running inside" \
  || nope "wake-lock intent hardcodes an application id — wrong app on every other instance"

# `am startservice` reports component resolution, not action validity: on
# galaxy both constants returned success, so a first-wins loop selects the
# first, not the working one. Both must be sent unconditionally.
grep -qE 'break|return 0' <(sed -n '/^  for _act in/,/^  done/p' "$SCRIPT") \
  && nope "wake-lock loop short-circuits — it picks the first constant, not a working one" \
  || ok "every wake-lock intent is sent (am cannot report which action is real)"

# The stamp bug: a disk cache of "already acquired" survives the Doze kill that
# dropped the lock, so the next start skips re-acquiring — precisely when the
# lock matters most. There must be no persisted held-state.
grep -q 'WAKELOCK_STAMP\|wake_lock_held' "$SCRIPT" \
  && nope "wake lock caches held-state on disk — it outlives the Doze reap it must survive" \
  || ok "no persisted wake-lock state (a stamp outlives the lock it records)"

# ── Cloud Unix Termux Boot contract ──────────────────────────────────────────────────
# The APK and the flake are two separately-deployed halves of one mechanism,
# and every failure between them is silent: the phone simply never comes up.
# These assertions are the only thing holding the halves together.
# The APK moved to the cloud-u-android repo (2026-08-27) — it is an Android
# product, not a flake. Override CLOUD_ANDROID to test against a checkout
# elsewhere; the [ -f ] guard below reports honestly when it is absent.
APK="${CLOUD_ANDROID:-$HOME/git/cloud-u-android}/a_solutions/ae-tool_termux-boot"

# RunCommandService refuses every foreign package unless this is set, and
# Cloud Unix Termux Boot is necessarily foreign (it cannot share the uid without the
# signing key). Without this line the APK installs, runs, and does nothing.
grep -q 'allow-external-apps=true' "$DIR/default.nix" \
  && ok "allow-external-apps set (RunCommandService rejects foreign callers otherwise)" \
  || nope "allow-external-apps unset — the boot APK is inert"

# The APK hardcodes one path because it cannot enumerate the 0700 boot dir.
# If these two disagree the intent resolves to a file that does not exist.
if [ -f "$APK/app/src/main/java/com/termux/nix/boot/BootReceiver.java" ]; then
  grep -q '\.termux/boot-runner\.sh' "$APK/app/src/main/java/com/termux/nix/boot/BootReceiver.java" \
    && grep -q '"\.termux/boot-runner\.sh"' "$DIR/default.nix" \
    && ok "APK entry point and flake-deployed runner path agree" \
    || nope "boot-runner path mismatch between APK and flake — boot silently does nothing"

  # TermuxService runs the command OUTSIDE proot, where /nix does not exist and
  # every files/usr/bin entry is a dangling symlink into /nix/store. Only
  # usr/bin/login (and proot-static) are real files out there. Executing the
  # boot script directly fails with "Cannot run program .../usr/bin/env" --
  # its own shebang cannot resolve. Measured on galaxy 2026-08-21.
  grep -q 'files/usr/bin/login' "$APK/app/src/main/java/com/termux/nix/boot/BootReceiver.java" \
    && grep -q 'RUN_COMMAND_ARGUMENTS' "$APK/app/src/main/java/com/termux/nix/boot/BootReceiver.java" \
    && ok "boot command enters proot via usr/bin/login (nothing under /nix runs outside it)" \
    || nope "APK executes the boot script directly — it cannot run outside proot"

  # A shared uid is impossible without F-Droid's key; declaring one makes the
  # APK uninstallable (INSTALL_FAILED_SHARED_USER_INCOMPATIBLE).
  grep -q 'android:sharedUserId=' "$APK/app/src/main/AndroidManifest.xml" \
    && nope "APK declares sharedUserId — it cannot install without F-Droid's signing key" \
    || ok "APK declares no sharedUserId (it cannot join the host uid)"
else
  nope "termux-boot APK not found at $APK — the boot APK half of the mechanism is absent"
fi

# ── every instance, not just the one that happens to work ────────────────
# The assertion above passed for two weeks while the phone's OTHER terminal had
# no ~/.termux/termux.properties at all: the declaration was correct, it simply
# never reached the renamed app (cld.termux.nix), whose activation aborted at
# Home Manager's checkHomeDirectory because the flake pinned home.homeDirectory
# to com.termux.nix at eval time. "One instance has it" is not the invariant.
# The invariant is "every instance the flake is declared to configure gets the
# same module set, and nothing in that set names one app".
FLAKE_ROOT="$(cd "$DIR/../../.." && pwd)"
FLAKE_SRC="$(cd "$DIR/../.." && pwd)"
BUILD_JSON="$FLAKE_ROOT/build.json"

if [ -f "$BUILD_JSON" ]; then
  INSTANCES="$(jq -r '.defaults.android_packages[]' "$BUILD_JSON" 2>/dev/null)"
  INSTANCE_N="$(printf '%s\n' "$INSTANCES" | grep -c . || true)"

  [ "$INSTANCE_N" -ge 1 ] \
    && ok "build.json declares the instance set ($INSTANCE_N: $(echo $INSTANCES | tr '\n' ' '))" \
    || nope "build.json declares no defaults.android_packages — nothing says which terminals this flake configures"

  # `default` is what CI builds and what a bare `--flake path:src` resolves to.
  # Pointing it at an instance that is not in the set means CI proves nothing
  # about anything the phone actually runs.
  DEFAULT_PKG="$(jq -r '.defaults.android_package // empty' "$BUILD_JSON" 2>/dev/null)"
  printf '%s\n' "$INSTANCES" | grep -qx "$DEFAULT_PKG" \
    && ok "defaults.android_package ($DEFAULT_PKG) is one of the declared instances" \
    || nope "defaults.android_package '$DEFAULT_PKG' is not in android_packages — the default configuration builds an unconfigured instance"

  # ONE builder. Two nixOnDroidConfiguration call sites would be two module
  # lists, and the second copy is exactly where allow-external-apps goes
  # missing for one app and nobody notices.
  BUILDERS="$(grep -c 'nix-on-droid.lib.nixOnDroidConfiguration' "$FLAKE_SRC/flake.nix")"
  [ "$BUILDERS" -eq 1 ] \
    && ok "one shared configuration builder (every instance gets the same modules)" \
    || nope "$BUILDERS configuration builders in flake.nix — instances can drift apart"

  grep -q 'android_packages' "$FLAKE_SRC/flake.nix" \
    && ok "the instance set is read from build.json, not typed into the flake" \
    || nope "flake.nix does not read defaults.android_packages — adding a terminal means editing code"

  grep -q './modules/cloud-ide-sshd' "$FLAKE_SRC/flake.nix" \
    && ok "this module is in the shared import list (so allow-external-apps reaches every instance)" \
    || nope "cloud-ide-sshd is not imported by the shared builder — the declaration reaches nothing"

  # The declaration reaching an instance is not enough if the activation dies
  # first. These two are what let a switch inside a non-default app get as far
  # as linkGeneration at all.
  grep -q 'user.home = lib.mkForce' "$FLAKE_SRC/modules/android-package.nix" \
    && ok "home directory follows the application id (checkHomeDirectory would abort otherwise)" \
    || nope "user.home not re-pointed — activation aborts before writing termux.properties on every non-default instance"

  grep -q 'build.installationDir = "/data/data/${androidPackage}' "$FLAKE_SRC/modules/android-package.nix" \
    && grep -q 'disabledModules = \[' "$FLAKE_SRC/flake.nix" \
    && ok "Termux prefix follows the application id (activation rewrites /bin/login from it)" \
    || nope "installationDir still upstream's literal — activating elsewhere overwrites that app's login with a foreign proot path"

  # THE CATCH. Every id literal outside build.json is a place the next instance
  # will be forgotten. Comments are exempt (they are where the history lives);
  # so are the .test.sh files, which never run on the device, and build.json,
  # which IS the declaration.
  STRAY="$(
    grep -rn --include='*.nix' --include='*.sh' --include='*.yaml' --include='*.json' \
      -e 'com\.termux\.nix' -e 'cld\.termux\.' "$FLAKE_SRC" 2>/dev/null \
      | grep -v '\.test\.sh:' \
      | grep -v '/build\.json:' \
      | grep -vE ':[0-9]+:[[:space:]]*#' || true
  )"
  if [ -z "$STRAY" ]; then
    ok "no application id is written out by hand in src/ (only build.json names one)"
  else
    nope "application id hardcoded outside build.json — every instance but that one breaks:"
    printf '%s\n' "$STRAY" | sed 's/^/      /'
  fi
else
  nope "build.json not found at $BUILD_JSON — cannot tell which instances this flake configures"
fi

# Home Manager leaves .hm-bak-<ts> copies beside replaced files; running them
# would execute several stale generations at once.
grep -q 'boot/\*\.sh' "$DIR/default.nix" \
  && ok "runner globs *.sh only (skips Home Manager .hm-bak backups)" \
  || nope "runner glob would execute stale .hm-bak generations"

grep -q 'termux-am' "$DIR/default.nix" \
  && ok "termux-am in runtimeInputs (am is how the lock is taken)" \
  || nope "am not on PATH — every intent will fail"

rm -f "$SANDBOX/.cache/sshd.pid"

# ── Phase 3 · ss blindness vs ss idleness ────────────────────────────────
# Android can leave `ss` present but unable to see anything (confirmed on
# galaxy: a live inbound session, and `ss -tln | grep 8024` printed nothing).
# Empty output therefore means either "nothing listening" or "not allowed to
# look", and treating blindness as idleness makes ensure rebind forever
# against a healthy daemon. These stub a fake `ss` to force each case.
echo "▶ Phase 3 · ss blind vs ss idle"

mkdir -p "$SANDBOX/.cache"
echo $$ > "$SANDBOX/.cache/sshd.pid"          # daemon "alive"
rm -f "$SANDBOX/.cache/sshd.rebind-stamp"     # cooldown not in the way

ss_stub() { printf '#!/bin/sh\n%s\n' "$1" > "$SANDBOX/bin/ss"; chmod +x "$SANDBOX/bin/ss"; }
run_status() {
  HOME="$SANDBOX" XDG_CONFIG_HOME="$SANDBOX/.config" \
  PATH="$SANDBOX/bin:$PATH" \
  CLOUD_IDE_SSHD_BIN="$SANDBOX/bin/sshd" \
  CLOUD_IDE_SSH_KEYGEN_BIN="$SANDBOX/bin/ssh-keygen" \
  CLOUD_IDE_SFTP_SERVER_BIN="$SANDBOX/bin/sftp-server" \
  bash "$SCRIPT" status 2>&1
}

# (a) blind ss: present, exits 0, prints nothing at all.
ss_stub 'exit 0'
case "$(run_status)" in
  *"127.0.0.1 ONLY"*) nope "blind ss treated as 'not listening' — would rebind a healthy daemon forever" ;;
  *)                  ok   "blind ss (no rows at all) treated as 'cannot tell'" ;;
esac

# (b) working ss that genuinely shows no sshd: LISTEN rows exist, none ours.
ss_stub "echo 'LISTEN 0 128 127.0.0.1:5432 0.0.0.0:*'"
case "$(run_status)" in
  *"127.0.0.1 ONLY"*) ok   "working ss with no wg0 listener correctly reports degraded" ;;
  *)                  nope "genuine 'not listening' went undetected" ;;
esac

# (c) working ss showing the wg0 listener: healthy.
ss_stub "echo 'LISTEN 0 128 [$WG_IP6]:$PORT [::]:*'"
case "$(run_status)" in
  *"127.0.0.1 ONLY"*) nope "v6 mesh listener present but reported degraded" ;;
  *)                  ok   "v6 listener counts as healthy (ss renders it [addr]:port)" ;;
esac

ss_stub "echo 'LISTEN 0 128 $WG_IP:$PORT 0.0.0.0:*'"
case "$(run_status)" in
  *"127.0.0.1 ONLY"*) nope "wg0 listener present but reported degraded" ;;
  *"$WG_IP"*)         ok   "wg0 listener detected as healthy" ;;
  *)                  nope "unexpected status output" ;;
esac

rm -f "$SANDBOX/bin/ss" "$SANDBOX/.cache/sshd.pid"

echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
