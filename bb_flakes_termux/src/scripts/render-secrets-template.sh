# render-secrets-template — sops-decrypt secrets.yaml and substitute ${VAR}
# placeholders in a template. Shared engine for ~/.mcp.json (claude) and
# ~/.gemini/settings.json — the two inline copies in flake.nix drifted apart
# and each independently grew the exit-0-aborts-activation and 0444-cp bugs.
# Env contract (wired by flake.nix): LABEL TPL OUT SECRETS_YAML SOPS_BIN
# YQ_BIN AWK_BIN. Never `exit` non-locally — flake wraps the call, but this
# script is also standalone-safe.
set -u
fresh_copy() { rm -f "$OUT"; cp "$TPL" "$OUT"; chmod 600 "$OUT"; }

if [ ! -f "$SOPS_BIN" ] || [ ! -f "$SECRETS_YAML" ] || [ ! -f "$TPL" ]; then
  echo "[$LABEL] WARNING: sops/secrets/template not found, copying template as-is"
  [ -f "$TPL" ] && fresh_copy
  exit 0
fi

DECRYPTED=$("$SOPS_BIN" -d "$SECRETS_YAML" 2>/dev/null) || true
if [ -z "$DECRYPTED" ]; then
  echo "[$LABEL] WARNING: failed to decrypt secrets.yaml"
  fresh_copy
  exit 0
fi

fresh_copy

# Extract ${VAR} placeholders with awk (no sed, no regex on secrets)
VARS=$("$AWK_BIN" '{
  s = $0
  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_-]*\}/)) {
    v = substr(s, RSTART+2, RLENGTH-3)
    print v
    s = substr(s, RSTART+RLENGTH)
  }
}' "$OUT" | sort -u) || true

# awk index() substitution — literal string match, no regex
for _var in $VARS; do
  _val=$(printf '%s' "$DECRYPTED" | "$YQ_BIN" -r ".[\"$_var\"]" 2>/dev/null) || true
  if [ -z "$_val" ] || [ "$_val" = "null" ]; then
    echo "[$LABEL] WARNING: $_var not found in secrets — leaving placeholder"
    continue
  fi
  _pat="\${${_var}}"
  "$AWK_BIN" -v pat="$_pat" -v rep="$_val" '{
    while (i = index($0, pat)) {
      $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
    }
    print
  }' "$OUT" > "$OUT.tmp"
  mv "$OUT.tmp" "$OUT"
done

chmod 600 "$OUT"
echo "[$LABEL] $OUT templated ($(echo $VARS | wc -w) vars substituted)"
