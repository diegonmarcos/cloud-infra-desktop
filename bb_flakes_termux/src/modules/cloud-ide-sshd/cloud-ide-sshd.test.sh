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
printf '{"wg_ip":"%s","ssh_port":%s}\n' "$WG_IP" "$PORT" \
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

grep -c '^ListenAddress ' "$CONF" | grep -qx 2 \
  && ok "exactly two listeners (wg0 + loopback)" \
  || nope "unexpected listener count"

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

rm -f "$SANDBOX/.cache/sshd.pid"
echo
printf '  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
