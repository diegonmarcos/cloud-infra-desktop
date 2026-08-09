# Claude Code — every ~/.claude declaration for this flake lives here.
#
# OWNERSHIP SPLIT — three owners, do not blur them:
#
#   my-ai BINARY  statusline-command.sh + claude-{mcp,plugins,hooks,flags}-status.sh
#                 + claude-pricing.json. The binary embeds them (core/src/
#                 statusline_assets.rs) and the daemon writes them into ~/.claude at
#                 startup. This module must NOT declare them: home.file would deploy a
#                 second copy over the top. That exact regression left the deployed
#                 status line 141 lines behind between 2026-08-01 and 2026-08-09.
#
#   my-ai REPO    Everything shared with ba_flakes_desktop — agents/,
#                 cloud-marketplace/, claude-plugins.json, rgignore, and the
#                 settings base+overlay. Consumed as my-ai's `claudeAssets` flake
#                 OUTPUT, never vendored: two vendored copies is exactly how
#                 cloud-marketplace drifted across 7 files (termux 2026-08-08 vs
#                 desktop 2026-07-30). Edit those files in da_my-ai, not here.
#
#   THIS FLAKE    Deploys, owns almost nothing. Platform-specific leftovers only:
#                 mcp.json.tpl (termux bans stdio MCP servers — 30s startup through
#                 proot), secrets.yaml (own sops recipients), the CLAUDE.md stub,
#                 and the out-of-store state symlinks.
{ config, lib, pkgs, claudeSrc, ... }:

let
  # settings.json = shared base ⊕ termux overlay.
  #
  # The base carries @HOME@ placeholders rather than absolute paths: every path that
  # used to differ between the two machines (GIT_BASE, NODE_PATH, both AUTHELIA_*_DIR,
  # statusLine.command) is byte-identical once $HOME is factored out, so they all live
  # in the base now and the overlay holds only real differences (refreshInterval, and
  # termux's MCP_TIMEOUT / effortLevel / enableAllProjectMcpServers).
  #
  # Substitution happens on the raw JSON text before parsing — home.homeDirectory is a
  # plain path with nothing needing JSON escaping. It is NOT left as a literal "$HOME"
  # because Claude Code shell-expands statusLine.command but sets env values verbatim,
  # so a literal there would leak "$HOME/git" into GIT_BASE.
  #
  # Verified against the pre-split files: desktop byte-identical, termux differs only
  # in statusLine.command (literal $HOME now pre-expanded — same resolved path).
  settingsJson = pkgs.writeText "claude-settings.json" (builtins.toJSON
    (lib.recursiveUpdate
      (builtins.fromJSON (builtins.replaceStrings [ "@HOME@" ] [ config.home.homeDirectory ]
        (builtins.readFile "${claudeSrc}/settings.base.json")))
      (builtins.fromJSON (builtins.readFile "${claudeSrc}/settings.termux.json"))));

  # Bulky runtime state lives in ~/git/.claude (429M — 376M of session transcripts +
  # 50M of file-history) so $HOME stays lean. Out-of-store symlinks: claude writes
  # through them at runtime and nix never copies the payload into the store.
  #
  # It must be $HOME/.claude pointing elsewhere, not the reverse. Claude Code reads
  # transcripts ONLY from the config dir ($CLAUDE_CONFIG_DIR, default ~/.claude); a
  # .claude/ inside a project folder is never scanned for sessions, so parking them in
  # ~/git/.claude alone leaves /resume blind. /resume additionally buckets by launch
  # cwd (dir name = slugified cwd at session start), so $HOME-rooted sessions only
  # list when claude starts from $HOME.
  stateDirs = [ "projects" "file-history" "session-env" "shell-snapshots" ];

  stateLinks = builtins.listToAttrs (map (d: {
    name = ".claude/${d}";
    value.source = config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/git/.claude/${d}";
  }) stateDirs);
in
{
  home.file = stateLinks // {
    # CLAUDE.md is a 1-char stub — all principles/reference content moved to
    # hooks-stack-framework-principles-cloud-ai-plugin (hooks-fragments/*.md, injected
    # via SessionStart/UserPromptSubmit hooks) in the SHARED cloud-marketplace.
    ".claude/CLAUDE.md".text = "\n";

    ".claude/mcp.json.tpl".source = ./assets/mcp.json.tpl;
    ".claude/secrets.yaml".source = ./assets/secrets.yaml;

    # Agent fleet manifest (explore/build/review/ops, all pinned model:sonnet).
    ".claude/agents" = {
      source = "${claudeSrc}/agents";
      recursive = true;
    };

    # Plugin/MCP status data for the statusline + claude-superset banner. The status
    # SCRIPTS come from the my-ai binary; only this manifest is declarative.
    ".claude/claude-plugins.json".source = "${claudeSrc}/claude-plugins.json";

    # cloud-marketplace — local Claude Code plugin marketplace holding the data-driven
    # hook engine and ponytail. Shared with ba_flakes_desktop via the my-ai SoT.
    ".claude/cloud-marketplace".source = "${claudeSrc}/cloud-marketplace";

    ".rgignore".source = "${claudeSrc}/rgignore";

    # claude-fix — diagnose & repair a shadowed/non-starting `claude` (stale npm shims
    # / leftover claude-tty wrappers / fish functions). Log: ~/claude-fix.log.
    "claude-fix.sh" = {
      source = ./assets/scripts/claude-fix.sh;
      executable = true;
    };
    # One-time sweep of the 2026-08 deepseek debugging leftovers. Idempotent — prints
    # "already gone" after the first run. Log: ~/deepseek-cleanup.log.
    "deepseek-cleanup.sh" = {
      source = ./assets/scripts/deepseek-cleanup.sh;
      executable = true;
    };
  };

  # settings.json deployed as a writable real file (not a nix-store symlink) so that
  # runtime commands (/effort, /model, /fast) can persist their writes. Source is
  # authoritative: each switch resets runtime prefs back to declared values.
  home.activation.claudeSettingsWritable = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    _dst="$HOME/.claude/settings.json"
    [ -L "$_dst" ] && rm "$_dst"
    ${pkgs.coreutils}/bin/install -m 600 ${settingsJson} "$_dst"
  '';

  # Register cloud-marketplace as a plugin marketplace (idempotent CLI call from a
  # nix-committed activation). claude-code is a real nix derivation on PATH here
  # (pkgs/claude-code native binary), not a curl-installed binary.
  home.activation.claudeMarketplace = lib.hm.dag.entryAfter [ "claudeSettingsWritable" ] ''
    JQ_BIN="${pkgs.jq}/bin/jq" \
    ${pkgs.bash}/bin/bash ${./assets/scripts/claude-marketplace-register.sh} || true
  '';

  # NO LOOSE SKILLS — same design as ba_flakes_desktop. ~/.claude/skills/ must stay
  # empty; every skill ships as a plugin (skill-<name>-plugin) in the SHARED
  # cloud-marketplace, enabled declaratively via settings.json enabledPlugins, and
  # unloads with its plugin.

  # MCP secrets: decrypt secrets.yaml → awk subst ''${VAR} → ~/.mcp.json
  # Mimics Docker env_file + init.sh pattern using awk index() (literal, no regex)
  # MCP secrets — engine lives in scripts/render-secrets-template.sh
  # (shared with geminiMcpSecrets; flake only wires paths/env).
  home.activation.mcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
    LABEL=mcp-secrets \
    TPL="$HOME/.claude/mcp.json.tpl" \
    OUT="$HOME/.mcp.json" \
    SECRETS_YAML="$HOME/.claude/secrets.yaml" \
    SOPS_BIN="$HOME/.nix-profile/bin/sops" \
    YQ_BIN="${pkgs.yq-go}/bin/yq" \
    AWK_BIN="${pkgs.gawk}/bin/awk" \
    ${pkgs.bash}/bin/bash ${../scripts/render-secrets-template.sh} || true
  '';
}
