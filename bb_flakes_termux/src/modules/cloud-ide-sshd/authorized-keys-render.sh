# authorized-keys-render — static trusted keys ALWAYS written first (a sops
# failure can never lock us out of WG SSH), then the Cloud IDE key appended
# best-effort from sops. Env contract: YQ_BIN, SECRETS, STATIC_KEYS_FILE.
SOPS="$HOME/.nix-profile/bin/sops"
# Pin the age identity to the on-device XDG path — an ambient
# SOPS_AGE_KEY_FILE may point at the desktop vault path.
[ -r "$HOME/.config/sops/age/keys.txt" ] && export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" || true
OUT="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
# Old generations symlinked this into the read-only store — drop before writing.
rm -f "$OUT"
cat "$STATIC_KEYS_FILE" > "$OUT"
if [ -f "$SOPS" ] && [ -f "$SECRETS" ]; then
  _key=$("$SOPS" -d "$SECRETS" 2>/dev/null | "$YQ_BIN" -r '.cloud_ide_authorized_keys' 2>/dev/null) || true
  if [ -n "$_key" ] && [ "$_key" != "null" ]; then
    printf '%s\n' "$_key" >> "$OUT"
    echo "[cloud-ide-sshd] authorized_keys: static keys + cloud-ide key"
  else
    echo "[cloud-ide-sshd] WARNING: cloud-ide key decrypt failed — static keys only"
  fi
fi
chmod 600 "$OUT"
