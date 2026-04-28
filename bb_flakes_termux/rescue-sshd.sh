#!/bin/sh
# Termux SSHD rescue — start dropbear directly via nix-shell, no flake rebuild.
# Pulls dropbear into the nix store, generates host key, daemonizes on :8022.
# Bypasses home-manager / nix-on-droid / openssh entirely.
#
# Usage on termux (any of these):
#   sh ~/git/unix/bb_flakes_termux/rescue-sshd.sh
#   curl -fsSL https://raw.githubusercontent.com/diegonmarcos/unix/main/bb_flakes_termux/rescue-sshd.sh | sh
set -eu

PORT=8022
KEY_DIR="$HOME/.ssh"
KEY_FILE="$KEY_DIR/dropbear_ed25519_host_key"
PID_FILE="$HOME/.cache/dropbear.pid"
LOG_FILE="$HOME/.cache/dropbear.log"
AUTH_KEYS="$KEY_DIR/authorized_keys"

C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YEL='\033[0;33m'; C_BLU='\033[0;36m'; C_RST='\033[0m'
ok()   { printf "${C_GREEN}[OK]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YEL}[WARN]${C_RST} %s\n" "$*"; }
fail() { printf "${C_RED}[FAIL]${C_RST} %s\n" "$*"; exit 1; }
step() { printf "\n${C_BLU}>>>${C_RST} %s\n" "$*"; }

# ── 1. Preflight ──────────────────────────────────────────────────────
step "1/5  Preflight"
command -v nix-shell >/dev/null 2>&1 || fail "nix-shell not found — broken nix install?"
mkdir -p "$KEY_DIR" "$(dirname "$PID_FILE")"
chmod 700 "$KEY_DIR"

# Bootstrap authorized_keys from repo if missing
if [ ! -s "$AUTH_KEYS" ]; then
  REPO_KEYS="$HOME/git/unix/bb_flakes_termux/src/modules/data/authorized-keys.json"
  if [ -f "$REPO_KEYS" ]; then
    # Extract pubkey strings without jq (POSIX awk)
    awk '/"ssh-/ { gsub(/^[[:space:]]*"|",?$/, ""); print }' "$REPO_KEYS" > "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    ok "wrote authorized_keys from repo ($(wc -l < "$AUTH_KEYS") keys)"
  else
    warn "no authorized_keys and repo file missing — only password auth will work (which dropbear disables by default)"
  fi
else
  ok "authorized_keys present ($(wc -l < "$AUTH_KEYS") lines)"
fi

# ── 2. Stop any existing sshd / dropbear ──────────────────────────────
step "2/5  Stop existing"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
fi
pkill -f 'dropbear|sshd' 2>/dev/null || true
rm -f "$PID_FILE" "$HOME/.cache/sshd.pid"
sleep 0.3
ok "cleaned"

# ── 3. Get dropbear via nix-shell ─────────────────────────────────────
step "3/5  Resolve dropbear binary (nix-shell)"
DROPBEAR=$(nix-shell -p dropbear --run 'echo $(command -v dropbear)' 2>/dev/null | tail -1)
DROPBEARKEY=$(nix-shell -p dropbear --run 'echo $(command -v dropbearkey)' 2>/dev/null | tail -1)
[ -x "$DROPBEAR" ]    || fail "could not resolve dropbear via nix-shell (got: $DROPBEAR)"
[ -x "$DROPBEARKEY" ] || fail "could not resolve dropbearkey via nix-shell (got: $DROPBEARKEY)"
ok "dropbear=$DROPBEAR"

# ── 4. Generate host key if missing ───────────────────────────────────
step "4/5  Host key"
if [ ! -f "$KEY_FILE" ]; then
  "$DROPBEARKEY" -t ed25519 -f "$KEY_FILE" >/dev/null 2>&1 || fail "dropbearkey failed"
  ok "generated $KEY_FILE"
else
  ok "$KEY_FILE exists"
fi

# ── 5. Start dropbear (background) ────────────────────────────────────
step "5/5  Start dropbear on :$PORT"
: > "$LOG_FILE"
# -p PORT, -r KEY, -P PIDFILE, -E (log to stderr -> file)
# No -F: dropbear backgrounds itself.
"$DROPBEAR" -p "$PORT" -r "$KEY_FILE" -P "$PID_FILE" -E >> "$LOG_FILE" 2>&1
sleep 0.5

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  ok "dropbear running (PID $(cat "$PID_FILE"))"
else
  fail "dropbear failed to start. Last 20 log lines:
$(tail -20 "$LOG_FILE" 2>/dev/null | sed 's/^/    /')"
fi

# ── Report ────────────────────────────────────────────────────────────
echo
LAN_IP=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2!~/^127\./ {sub(/\/.*/,"",$2); print $2; exit}')
WG_IP=$(ip -4 addr show wg0 2>/dev/null | awk '/inet / {sub(/\/.*/,"",$2); print $2}')
LISTEN=$(ss -tln 2>/dev/null | awk -v p=":$PORT" '$0 ~ p {print; exit}')

printf "${C_GREEN}════════════ SSHD UP ════════════${C_RST}\n"
[ -n "$LISTEN" ] && echo "  $LISTEN"
echo "  PID:       $(cat "$PID_FILE" 2>/dev/null)"
[ -n "$LAN_IP" ] && echo "  LAN ssh:   ssh -p $PORT nix-on-droid@$LAN_IP"
[ -n "$WG_IP" ]  && echo "  WG  ssh:   ssh -p $PORT nix-on-droid@$WG_IP"
echo "  log:       $LOG_FILE"
echo "  pidfile:   $PID_FILE"
echo "  hostkey:   $KEY_FILE"
