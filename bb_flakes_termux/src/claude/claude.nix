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
#                 settings base+overlay. Read from the WORKING CHECKOUT at
#                 activation time (assets/scripts/claude-settings-merge.sh +
#                 claude-assets-deploy.sh), never vendored and never through a
#                 pinned flake input — a pin only updates on `nix flake update
#                 my-ai` + a switch, and it sat stale 2026-08-18 to 2026-08-20
#                 while cleanupPeriodDays landed in the SoT, silently deploying
#                 pre-fix settings for two days. Same fix ba_flakes_desktop
#                 already uses (home.activation.claudeSettings /
#                 claudeAssets there). Edit those files in da_my-ai, not here.
#
#   THIS FLAKE    Deploys, owns almost nothing: secrets.yaml (own sops
#                 recipients — genuinely un-shareable), the CLAUDE.md stub, and
#                 the out-of-store state symlinks. 2026-08-27: mcp.json.tpl left
#                 too, to da_my-ai as mcp.termux.json.tpl. Termux banning the
#                 stdio servers is a CONTENT difference, not an ownership one —
#                 the suffix carries the platform, the directory carries the SoT,
#                 exactly as settings.termux.json already did.
{ config, lib, pkgs, ... }:

let
  # The ONE SoT, read at activation (never at eval — a `path:` flake input
  # escaping src/ would copy the whole ~3.6GB repo into the Nix store and kill
  # proot mid-copy; `path:../../da_my-ai` is rejected outright by Nix 2.18 as
  # "relative path points outside of its parent's store path"). Overridable
  # for a non-standard checkout. See assets/scripts/claude-settings-merge.sh
  # and claude-assets-deploy.sh for the activation-time read + the "no
  # fallback, fail loud" rationale.
  claudeSotDefault = "${config.home.homeDirectory}/git/cloud-u-linux/da_my-ai/data/claude";

  # Bulky runtime state lives in the memory repo, under a_sessions/<instance>/ — the
  # same arrangement surface uses, so both devices' transcripts are versioned and
  # syncable instead of only surface's. It stays out of $HOME's own tree either way. Out-of-store symlinks: claude writes
  # through them at runtime and nix never copies the payload into the store.
  #
  # It must be $HOME/.claude pointing elsewhere, not the reverse. Claude Code reads
  # transcripts ONLY from the config dir ($CLAUDE_CONFIG_DIR, default ~/.claude); a
  # .claude/ inside a project folder is never scanned for sessions, so parking them in
  # ~/git/.claude alone leaves /resume blind. /resume additionally buckets by launch
  # cwd (dir name = slugified cwd at session start), so $HOME-rooted sessions only
  # list when claude starts from $HOME.
  stateDirs = [ "projects" "file-history" "session-env" "shell-snapshots" ];

  # This device's name in the memory repo. It used to be written out at each of
  # the three places that needed it; it is one binding now, because the archive
  # buckets per-device state under a_sessions/<instance>/ AND sync-sessions.sh
  # stamps its commit subject with the same word, and a device that disagreed
  # with itself would file its transcripts under a directory nobody reads.
  # ba_flakes_desktop says "surface" the same way.
  instance = "galaxy";

  # Where the archive is cloned. Same default the claudeMemoryLinks activation
  # below uses, and the same one bin/sync-sessions.sh resolves itself from.
  memoryRepoDefault = "${config.home.homeDirectory}/git/cloud-data-my-ai-memory";

  stateLinks = builtins.listToAttrs (map (d: {
    name = ".claude/${d}";
    value.source = config.lib.file.mkOutOfStoreSymlink
      "${memoryRepoDefault}/a_sessions/${instance}/${d}";
  }) stateDirs);

  # The archiver's trigger on a device with no scheduler. Body and the full
  # "why a shell start" argument in assets/scripts/claude-sync-sessions.sh;
  # the start sites are modules/programs/shells/fish/interactiveShellInit.fish
  # and modules/programs/shells/bash.nix, which is where this device's other
  # shell-triggered services already live.
  #
  # runtimeEnv carries the instance name because sync-sessions.sh falls back to
  # `hostname` without it, and Android does not let this app sethostname() —
  # `hostname -s` answers "localhost" here (flake.nix records that, which is why
  # dtk_node exists at all), so every commit would be filed under "localhost".
  claudeSyncSessionsPkg = pkgs.writeShellApplication {
    name = "claude-sync-sessions";
    runtimeInputs = with pkgs; [
      bash git jq coreutils findutils gnugrep gawk util-linux openssh
    ];
    runtimeEnv = { CLAUDE_INSTANCE = instance; };
    text = builtins.readFile ./assets/scripts/claude-sync-sessions.sh;
  };
in
{
  home.file = stateLinks // {
    # CLAUDE.md is a 1-char stub — all principles/reference content moved to
    # hooks-stack-framework-principles-cloud-ai-plugin (hooks-fragments/*.md, injected
    # via SessionStart/UserPromptSubmit hooks) in the SHARED cloud-marketplace.
    ".claude/CLAUDE.md".text = "\n";

    # mcp.json.tpl WAS here, i.e. a second SoT for claude settings. It moved to
    # da_my-ai/data/claude/mcp.termux.json.tpl on 2026-08-27 and is deployed
    # by claude-assets-deploy.sh (MCP_VARIANT=termux). secrets.yaml STAYS: sops
    # ciphertext keyed to this flake's own age recipients, not settings.
    ".claude/secrets.yaml".source = ./assets/secrets.yaml;

    # agents/, claude-plugins.json, cloud-marketplace/ and rgignore are NOT
    # home.file entries any more — they moved to home.activation.claudeAssets
    # below, copied from the working checkout at activation time instead of
    # through the (formerly pinned) my-ai flake input. See the OWNERSHIP
    # SPLIT comment at the top of this file.

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

  # On PATH so the two shell start sites can guard on `command -v` before
  # calling it, exactly as they already do for etc-self-heal and my-webserver.
  home.packages = [ claudeSyncSessionsPkg ];

  # Agent fleet, cloud-marketplace, claude-plugins.json, rgignore — copied from
  # the working checkout at activation time. See claude-assets-deploy.sh.
  home.activation.claudeAssets = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    REPO_SOT="''${CLAUDE_SOT_DIR:-${claudeSotDefault}}" \
    DEST_CLAUDE="$HOME/.claude" \
    DEST_RGIGNORE="$HOME/.rgignore" \
    MCP_VARIANT=termux \
    CP_BIN="${pkgs.coreutils}/bin/cp" \
    RM_BIN="${pkgs.coreutils}/bin/rm" \
    MKDIR_BIN="${pkgs.coreutils}/bin/mkdir" \
    CHMOD_BIN="${pkgs.coreutils}/bin/chmod" \
    ${pkgs.bash}/bin/bash ${./assets/scripts/claude-assets-deploy.sh}
  '';

  # settings.json deployed as a writable real file (not a nix-store symlink) so that
  # runtime commands (/effort, /model, /fast) can persist their writes. Source is
  # authoritative: each switch resets runtime prefs back to declared values.
  #
  # Read from the working checkout at activation, same as claudeAssets above —
  # NO flake-input fallback, deliberately: a fallback is a second source that
  # can silently disagree with the SoT, which is the exact bug this replaces
  # (2026-08-18 to 2026-08-20, a stale `my-ai` lock deployed pre-fix settings
  # for two days with no error). See claude-settings-merge.sh.
  home.activation.claudeSettingsWritable = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    REPO_SOT="''${CLAUDE_SOT_DIR:-${claudeSotDefault}}" \
    OVERLAY="settings.termux.json" \
    DST="$HOME/.claude/settings.json" \
    HOME_DIR="${config.home.homeDirectory}" \
    SED_BIN="${pkgs.gnused}/bin/sed" \
    JQ_BIN="${pkgs.jq}/bin/jq" \
    ${pkgs.bash}/bin/bash ${./assets/scripts/claude-settings-merge.sh}
  '';

  # Register cloud-marketplace as a plugin marketplace (idempotent CLI call from a
  # nix-committed activation). claude-code is a real nix derivation on PATH here
  # (pkgs/claude-code native binary), not a curl-installed binary.
  home.activation.claudeMarketplace = lib.hm.dag.entryAfter [ "claudeAssets" "claudeSettingsWritable" ] ''
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
  # ── memory / prompt-history symlinks ───────────────────────────────────────
  # The durable state (MEMORY.md, memory-entries/, history.jsonl) lives in the
  # cloud-data-my-ai-memory repo, NOT in ~/.claude. ~/.claude only holds links pointing in.
  #
  # Why: 2026-08-20 an absent cleanupPeriodDays let Claude Code's built-in
  # 30-day default silently delete ~2.5 months of transcripts. Nothing was
  # recoverable — @snapshots/home-diego is empty and ~/git is on @nosnap. The
  # retention pin in settings.base.json stops expiry but not disk loss, so the
  # state now lives in a repo with a remote. Links are recreated here so a
  # rebuild reasserts them instead of leaving whatever is on disk.
  #
  # This NEVER deletes a real file: anything non-symlink in the way is moved
  # aside to .bak-<timestamp> and reported, so a desync is loud, not lossy.
  home.activation.claudeMemoryLinks = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    MEM_REPO="''${CLAUDE_MEMORY_REPO:-${memoryRepoDefault}}"
    INSTANCE="${instance}"
    # Claude Code buckets projects by slugified $HOME (/home/diego -> -home-diego;
    # on termux -> -data-data-com-termux-files-home). Derive it rather than hardcode,
    # so this same block is correct on every instance. Both devices link the SAME
    # b_projects/home-diego: memory is shared, only a_sessions/ is per-instance.
    PROJ="$HOME/.claude/projects/$(echo "$HOME" | ${pkgs.gnused}/bin/sed 's#/#-#g')"

    if [ ! -d "$MEM_REPO/.git" ]; then
      echo "[claude-memory] WARNING: $MEM_REPO is not a checkout — links left as-is." >&2
      echo "[claude-memory]   git clone git@github.com:diegonmarcos/cloud-data-my-ai-memory.git $MEM_REPO" >&2
    else
      link_in() {
        SRC="$1"; DEST="$2"
        if [ ! -e "$SRC" ]; then
          echo "[claude-memory] WARNING: missing in repo, skipped: $SRC" >&2
          return 0
        fi
        # A real file/dir here means the repo and disk disagree. Preserve it.
        if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
          STAMP="$DEST.bak-$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)"
          echo "[claude-memory] NOTICE: real path at $DEST -> preserved as $STAMP" >&2
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv -f "$DEST" "$STAMP"
        fi
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$DEST")"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$SRC" "$DEST"
      }

      link_in "$MEM_REPO/b_projects/home-diego/MEMORY.md"      "$PROJ/memory/MEMORY.md"
      link_in "$MEM_REPO/b_projects/home-diego/memory-entries" "$PROJ/memory-entries"
      link_in "$MEM_REPO/a_sessions/$INSTANCE/history.jsonl"   "$HOME/.claude/history.jsonl"

      # The archive's pre-commit blob check is per-clone LOCAL state — git
      # reads core.hooksPath from .git/config, which no clone inherits and no
      # commit carries. So the check that refuses a commit carrying a blob
      # GitHub will reject was, until this line, protection that existed only
      # on a machine where somebody had remembered to type one command. Assert
      # it on every switch instead; it is a no-op once set.
      #
      # `|| echo` and never bare: this activation block is NOT wrapped in a
      # subshell, and home-manager runs the whole activation under `set -e`, so
      # an unguarded git failure here (index locked by a concurrent agent,
      # config not writable) would abort the entire switch on a device whose
      # owner is standing in front of it. A repo that is not cloned at all
      # never reaches this line — it is inside the `.git` test above, whose
      # else-branch only warns.
      if [ -d "$MEM_REPO/bin/hooks" ]; then
        ${pkgs.git}/bin/git -C "$MEM_REPO" config core.hooksPath bin/hooks \
          && echo "[claude-memory] core.hooksPath -> bin/hooks (pre-commit blob check armed)" \
          || echo "[claude-memory] WARNING: could not set core.hooksPath in $MEM_REPO" >&2
      fi
      echo "[claude-memory] linked into $MEM_REPO (instance: $INSTANCE)"
    fi
  '';

}
