# jq wrappers + JSON validation helpers

# Read a key from boot.json, e.g.: jq_get '.uefi.esp.uuid'
jq_get() {
    jq -r "$1" "$BOOT_JSON"
}

# Validate boot.json against schema (requires `ajv` or fallback to jq -e)
validate_json() {
    local json="$1"
    local schema="$2"

    if ! jq empty "$json" 2>/dev/null; then
        error "Malformed JSON: $json"
        return 1
    fi

    if command -v ajv >/dev/null 2>&1; then
        ajv validate -s "$schema" -d "$json" 2>&1
    elif command -v check-jsonschema >/dev/null 2>&1; then
        check-jsonschema --schemafile "$schema" "$json"
    else
        warn "No JSON schema validator (ajv / check-jsonschema) — skipping schema check"
        warn "Install with: nix-shell -p check-jsonschema"
        # Just check it parses
        jq empty "$json"
    fi
}
