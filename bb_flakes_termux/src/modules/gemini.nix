# Gemini CLI — settings template + the sops render pass. Shares the render engine
# and the secrets file with claude/claude.nix (SECRETS_YAML is ~/.claude/secrets.yaml).
{ config, lib, pkgs, ... }:

{
  # Gemini CLI configuration + MCP server config
  home.file.".gemini/settings.json.tpl".source = ./dotfiles/gemini/settings.json.tpl;
  # Gemini CLI: decrypt secrets.yaml → awk subst ''${VAR} → ~/.gemini/settings.json
  home.activation.geminiMcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
    LABEL=gemini-mcp \
    TPL="$HOME/.gemini/settings.json.tpl" \
    OUT="$HOME/.gemini/settings.json" \
    SECRETS_YAML="$HOME/.claude/secrets.yaml" \
    SOPS_BIN="$HOME/.nix-profile/bin/sops" \
    YQ_BIN="${pkgs.yq-go}/bin/yq" \
    AWK_BIN="${pkgs.gawk}/bin/awk" \
    ${pkgs.bash}/bin/bash ${../scripts/render-secrets-template.sh} || true
  '';
}
