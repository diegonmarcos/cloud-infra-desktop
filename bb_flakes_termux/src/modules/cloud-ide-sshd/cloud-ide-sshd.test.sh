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
chmod +x "$SANDBOX/bin/sshd" "$SANDBOX/bin/ssh-keygen"

run() {
  HOME="$SANDBOX" XDG_CONFIG_HOME="$SANDBOX/.config" \
  CLOUD_IDE_SSHD_BIN="$SANDBOX/bin/sshd" \
  CLOUD_IDE_SSH_KEYGEN_BIN="$SANDBOX/bin/ssh-keygen" \
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
# differs between Termux and its fork, so both must be attempted.
grep -q 'com.termux.nix.service_wake_lock' "$SCRIPT" \
  && grep -q 'com.termux.service_wake_lock' "$SCRIPT" \
  && ok "both wake-lock intent constants attempted (fork + upstream)" \
  || nope "only one intent constant tried — a wrong guess means no lock at all"

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
