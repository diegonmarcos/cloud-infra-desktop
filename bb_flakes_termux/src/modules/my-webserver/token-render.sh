# httpd write-API shared secret — decrypts the sops-encrypted token to a 0600
# file the server reads once at startup (HTTPD_WRITE_TOKEN_FILE).
#
# Modelled on ../cloud-ide-sshd/authorized-keys-render.sh, but the fail-safe
# direction is deliberately the opposite. There, static keys are written first
# so a sops failure can never lock us out of SSH. Here a sops failure must
# leave NO token, because the server fails closed: no token means the write
# API refuses everything. Losing the ability to write posts is the correct
# outcome of a decrypt failure; silently writing an empty or stale-open token
# is not.
#
# Env contract: YQ_BIN, SECRETS, OUT.
SOPS="$HOME/.nix-profile/bin/sops"

# Pin the age identity to the on-device XDG path — an ambient SOPS_AGE_KEY_FILE
# may point at the desktop vault path (same trap cloud-ide-sshd documents).
[ -r "$HOME/.config/sops/age/keys.txt" ] && export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" || true

OUT="${OUT:-$HOME/.cache/my-webserver.token}"
mkdir -p "$(dirname "$OUT")"

if [ ! -f "$SOPS" ] || [ ! -f "$SECRETS" ]; then
  echo "[my-webserver] NOTE: sops or secrets.yaml missing — write API stays disabled"
  exit 0
fi

_tok=$("$SOPS" -d "$SECRETS" 2>/dev/null | "$YQ_BIN" -r '.httpd_write_token' 2>/dev/null) || true
if [ -z "$_tok" ] || [ "$_tok" = "null" ]; then
  echo "[my-webserver] WARNING: token decrypt failed — write API stays disabled"
  exit 0
fi

# Old generations may have symlinked this into the read-only store.
rm -f "$OUT"
# umask in a subshell so the token is never briefly world-readable between
# creation and chmod.
( umask 077; printf '%s\n' "$_tok" > "$OUT" )
chmod 600 "$OUT"
echo "[my-webserver] write token rendered (${#_tok} chars)"
