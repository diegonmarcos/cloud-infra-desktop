# Claude Code — every ~/.claude declaration for this flake lives here.
#
# OWNERSHIP SPLIT — three owners, do not blur them:
#
#   my-ai BINARY  statusline-command.sh + claude-{mcp,plugins,hooks,flags}-status.sh
#                 + claude-pricing.json. The binary embeds them (core/src/
#                 statusline_assets.rs) and the daemon writes them into ~/.claude at
#                 startup. This module must NOT declare them. Desktop already got
#                 this right; bb_flakes_termux had re-added them and its deployed
#                 status line sat 141 lines stale from 2026-08-01 to 2026-08-09.
#
#   my-ai REPO    Assets shared with bb_flakes_termux — agents/, cloud-marketplace/,
#                 claude-plugins.json, rgignore, settings.{base,desktop}.json. Pulled
#                 through the `my-ai` flake input rather than vendored, because two
#                 vendored copies is precisely how cloud-marketplace drifted across
#                 7 files (desktop 2026-07-30 vs termux 2026-08-08).
#
#   THIS FLAKE    secrets.yaml (sops ciphertext keyed to this flake's own age
#                 recipients — genuinely un-shareable) and the CLAUDE.md stub.
#                 NOTHING ELSE. 2026-08-27: mcp.json.tpl and mcp-local-launch.sh
#                 moved to the my-ai REPO as mcp.desktop.json.tpl and
#                 mcp-local-launch.sh. "Platform-specific" is not a reason to own
#                 a second copy — settings.desktop.json is platform-specific and
#                 lives in the SoT; the suffix carries the platform, the
#                 directory carries the ownership.
{ config, lib, pkgs, inputs, ... }:

let
  # claudeSrc (inputs.my-ai-src.claudeAssets) is GONE — 2026-08-12, ONE SoT.
  # Every claude asset now comes from the working checkout at activation time.
  # The my-ai-src input still exists in flake.nix for the my-ai BINARY, which
  # genuinely is a build product and must stay pinned; nothing about ~/.claude
  # config passes through it any more.

  # settings.json = shared base ⊕ desktop overlay.
  #
  # The base carries @HOME@ placeholders rather than absolute paths: every path that
  # used to differ between the two machines (GIT_BASE, NODE_PATH, both AUTHELIA_*_DIR,
  # statusLine.command) is byte-identical once $HOME is factored out, so they all live
  # in the base now and the overlay holds only real differences (refreshInterval, tui,
  # and the four desktop-only LSP plugins).
  #
  # Substitution happens on the raw JSON text before parsing. It is NOT left as a
  # literal "$HOME" because Claude Code shell-expands statusLine.command but sets env
  # values verbatim, so a literal there would leak "$HOME/git" into GIT_BASE.
  #
  # Verified against the pre-split file: byte-identical on this machine.
  # GENERATED-FILE HEADER. JSON has no comments, so the banner every other
  # generated artifact in this repo carries (see 1_configs inject_header) is a
  # `_generated` FIELD instead, injected by the ENGINE — a source file must not
  # claim to be generated, and the marker belongs in the OUTPUT, the file people
  # actually open and mistakenly hand-edit. It now lives inline in the jq filter
  # in claudeSettings below, because the merge moved to activation time and a
  # Nix-side attrset could no longer reach it.
  #
  # settingsJson (the eval-time base⊕overlay merge from the flake input) is GONE.
  # The merge now happens at activation from the checkout — see
  # home.activation.claudeSettings. Keeping a store-built copy around would
  # recreate the two-sources problem this removed.
  #
  # The ONE SoT, read at activation. Overridable for a non-standard checkout.
  claudeSotDefault = "${config.home.homeDirectory}/git/cloud-u-linux/da_my-ai/data/claude";
in
{
  # Agent fleet (explore/build/review/ops, pinned model:sonnet). dotfiles/claude/agents
  # existed here but was NEVER declared, so desktop has never deployed the fleet —
  # that is why desktop sessions start with no agents. Now shared from the my-ai SoT.

  # Claude Code configuration + MCP server config
  # CLAUDE.md is now a 1-char stub — all principles/reference content moved to
  # cloud-principles-ai-plugin (hooks-fragments/*.md, injected via SessionStart/
  # UserPromptSubmit hooks) to eliminate the double-injection (static file +
  # hook injection of the same text) that was bloating every session's fixed
  # context. See da_my-ai/data/claude/cloud-marketplace/.
  # ── Shared claude assets, from the SAME single SoT as settings.json ────────
  # agents/, cloud-marketplace/, claude-plugins.json and rgignore were home.file
  # entries pointing at the my-ai flake input. That is the same two-sources
  # problem settings.json had: editing an agent or a marketplace plugin meant
  # commit + push + `nix flake update my-ai` before a switch could see it, and
  # until that happened the deployed copy was silently whatever the lock file
  # last pinned. They are inert data that nothing needs at eval time.
  #
  # TRADEOFF, stated: home.file tracked these and removed them when undeclared.
  # A copy does not, so deleting an agent from the SoT now leaves the stale file
  # in ~/.claude. Hence agents/ and cloud-marketplace/ are wiped-then-copied
  # rather than merged — for a directory that is the whole of the semantics.
  # Single files cannot be swept that way; a removed one must be deleted by hand.
  home.activation.claudeAssets = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    SOT="''${CLAUDE_SOT_DIR:-${claudeSotDefault}}"
    CP="${pkgs.coreutils}/bin/cp"
    RM="${pkgs.coreutils}/bin/rm"
    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.claude"
    if [ ! -d "$SOT" ]; then
      echo "[claude-assets] FATAL: SoT missing at $SOT — assets NOT deployed" >&2
      exit 1
    fi
    for d in agents cloud-marketplace; do
      if [ -d "$SOT/$d" ]; then
        $RM -rf "$HOME/.claude/$d"
        $CP -a "$SOT/$d" "$HOME/.claude/$d"
      else
        echo "[claude-assets] WARN: $SOT/$d absent — left as-is" >&2
      fi
    done
    [ -f "$SOT/claude-plugins.json" ] && $CP -f "$SOT/claude-plugins.json" "$HOME/.claude/claude-plugins.json"
    [ -f "$SOT/rgignore" ]           && $CP -f "$SOT/rgignore"           "$HOME/.rgignore"
    # Platform-suffixed exactly like settings.desktop.json: the file is
    # desktop-only (termux bans the stdio servers it declares) but it is still
    # claude SETTINGS, so it lives in the one SoT dir, not beside the flake.
    [ -f "$SOT/mcp.desktop.json.tpl" ] && $CP -f --no-preserve=mode "$SOT/mcp.desktop.json.tpl" "$HOME/.claude/mcp.json.tpl"
    if [ -f "$SOT/mcp-local-launch.sh" ]; then
      $CP -f --no-preserve=mode "$SOT/mcp-local-launch.sh" "$HOME/.claude/mcp-local-launch.sh"
      ${pkgs.coreutils}/bin/chmod 0755 "$HOME/.claude/mcp-local-launch.sh"
    fi
    ${pkgs.coreutils}/bin/chmod -R u+w "$HOME/.claude/agents" "$HOME/.claude/cloud-marketplace" 2>/dev/null || true
    echo "[claude-assets] deployed from $SOT (single SoT)"
    ) || echo "[claude-assets] subshell failed; HM chain continues"
  '';

  home.file.".claude/CLAUDE.md".text = "\n";
  # mcp.json.tpl and mcp-local-launch.sh WERE home.file entries pointing at
  # ./assets/. That made this flake a second SoT for claude settings, and it
  # cost exactly what a second SoT always costs: cloud-infra declared
  # cloud-cgc-pvt-mcp on 2026-08-23 and the client-side list here never heard
  # about it. Both now come from the ONE SoT via home.activation.claudeAssets.
  #
  # secrets.yaml STAYS. It is sops ciphertext keyed to THIS flake's age
  # recipients, not settings — the termux flake has its own, and a shared copy
  # would be undecryptable on one of the two machines.
  home.file.".claude/secrets.yaml".source = ./assets/secrets.yaml;
  # ── The status line is OWNED BY THE my-ai BINARY, not by this flake ────────
  #
  # statusline-command.sh, claude-{mcp,plugins,hooks,flags}-status.sh and
  # claude-pricing.json used to be home.file entries here. That split ONE feature
  # across two release cadences: the `05h-T` label was a Rust format string
  # needing a GHA round-trip, while `All-S` and `05h-S` beside it were a file
  # copy. And the daemon shells out to those scripts to build `.blocks`, so the
  # binary had an undeclared dependency on files this flake shipped — upgrade one
  # without the other and `.blocks` goes silently empty, sending every session
  # back to spawning five scripts per render.
  #
  # my-ai now embeds them (core/src/statusline_assets.rs) and writes them out on
  # every daemon start, so whatever binary is running is running against the
  # assets that shipped with it. This flake keeps exactly one decision:
  # settings.json, which says WHERE the status line appears. my-ai decides WHAT
  # it is. Update them in da_my-ai/data/statusline/.
  #
  # claude-plugins.json stays here: it is machine configuration (which plugins
  # this host has), not part of the status line's implementation.
  # cloud-marketplace — local Claude Code plugin marketplace holding:
  #   - cloud-principles-ai-plugin: the data-driven hook engine (was
  #     ~/.claude/hooks/*) — ONE engine + ONE registry (hooks-rules.json):
  #       inject <tier> → SessionStart / UserPromptSubmit / PreToolUse context
  #       guard         → PreToolUse(Bash) allow/deny/warn (fail-closed)
  #       nudge         → PostToolUse soft graph nudge
  #   - ponytail: "lazy senior dev" skill (vendored, DietrichGebert/ponytail
  #     @ 6da37bf, MIT), moved in from its old standalone ~/.claude/ponytail/.
  # Registered as a real plugin marketplace (not settings.json hooks) so both
  # are independently toggleable via `/plugin` — e.g. disable
  # cloud-principles-ai-plugin for a lean Sonnet 200k session without a
  # source edit. See claudeMarketplace activation below for registration.
  # settings.json: deployed WRITABLE (not a read-only store symlink) so the
  # runtime `/effort` command can persist effortLevel. Nix owns the baseline
  # (hooks, statusline, env, plugins) and refreshes it every switch; effortLevel
  # is NOT nix-managed — it's a runtime decision, preserved across rebuilds.
  # Same writable-runtime-file pattern as ~/.mcp.json and ~/.gemini/settings.json.
  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    JQ="${pkgs.jq}/bin/jq"
    DST="$HOME/.claude/settings.json"
    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.claude"

    # ── ONE SOURCE OF TRUTH: the working checkout. No flake fallback. ───────
    # Reading these at ACTIVATION (they are never needed at eval) collapses
    #   edit -> commit + push -> nix flake update my-ai -> build.sh switch
    # down to `build.sh switch`. The flake input could not do this: a flake may
    # only reference paths under its own root, ba_flakes_desktop/src/ is that
    # root, and da_my-ai/ sits outside it — structural to flakes, not the Nix
    # 2.18 relative-path bug claude/README.md blames (Nix here is 2.24.14 and
    # the restriction is identical).
    #
    # NO FALLBACK, deliberately. A fallback means two sources that can disagree,
    # and the failure is silent: the machine keeps working while quietly serving
    # stale config from whenever the flake input was last updated. Failing loudly
    # is the point — one SoT or an error, never a guess.
    REPO_SOT="''${CLAUDE_SOT_DIR:-$HOME/git/cloud-u-linux/da_my-ai/data/claude}"
    if [ ! -r "$REPO_SOT/settings.base.json" ] || [ ! -r "$REPO_SOT/settings.desktop.json" ]; then
      echo "[claude-settings] FATAL: SoT missing at $REPO_SOT" >&2
      echo "[claude-settings] ~/.claude/settings.json left UNCHANGED. Clone the repo there, or set CLAUDE_SOT_DIR." >&2
      exit 1
    fi
    LIVE="$HOME/.claude/.settings-merged.$$"
    # jq's * is a RECURSIVE object merge, matching lib.recursiveUpdate — a plain
    # + replaces whole sub-objects and would silently drop base keys the overlay
    # does not restate.
    if ! ${pkgs.gnused}/bin/sed "s|@HOME@|$HOME|g" "$REPO_SOT/settings.base.json" \
         | "$JQ" -s --slurpfile ov "$REPO_SOT/settings.desktop.json" \
             '.[0] * $ov[0] * {_generated: "GENERATED FILE — DO NOT EDIT. Source: da_my-ai/data/claude/settings.base.json + settings.desktop.json (the ONE SoT, read from the working checkout at activation). Engine: ba_flakes_desktop/src/claude/claude.nix (home.activation.claudeSettings). Rebuild: ba_flakes_desktop/build.sh switch."}' \
             > "$LIVE" 2>/dev/null || [ ! -s "$LIVE" ]; then
      ${pkgs.coreutils}/bin/rm -f "$LIVE"
      echo "[claude-settings] FATAL: merge of base+overlay failed — settings.json left UNCHANGED" >&2
      exit 1
    fi
    SRC="$LIVE"
    echo "[claude-settings] source: $REPO_SOT (single SoT)"
    # Runtime-owned keys: written by the CLI itself (/effort, /model, /config,
    # the auto-mode environment onboarding), never declared in the SoT. They are
    # merged back ON TOP of the generated file, so a switch cannot destroy them.
    #
    # 2026-08-23: this list was just effortLevel, and `autoMode` was the cost.
    # Answering "Teach auto mode about your environment?" stores the whole
    # learned environment here under `autoMode`; the next switch regenerated
    # settings.json without it and the prompt came straight back — twelve times
    # (projectOnboardingSeenCount=12 for /home/diego), which is what made it look
    # like a dismissal bug rather than a config-wipe bug. Any key the CLI owns
    # and we do not declare belongs in this list, or every rebuild deletes it.
    #
    # 2026-08-27: effortLevel LEFT this list. It is now declared in
    # settings.base.json ("max"), so the SoT is the default and a switch
    # re-asserts it. /effort still works — it just lasts until the next switch,
    # which is what "default" means. A key cannot be both declared and
    # runtime-owned: the runtime copy is merged on top, so it would always win
    # and the declaration would be decoration.
    RUNTIME_KEYS='["autoMode","model","tui"]'
    KEEP=""
    if [ -f "$DST" ] && [ ! -L "$DST" ]; then
      KEEP=$("$JQ" -c --argjson k "$RUNTIME_KEYS" \
        'with_entries(select(.key as $x | $k | index($x)))' "$DST" 2>/dev/null) || KEEP=""
    fi
    [ -n "$KEEP" ] || KEEP="{}"
    # Drop any stale read-only store symlink left by the old home.file mechanism.
    [ -L "$DST" ] && ${pkgs.coreutils}/bin/rm -f "$DST"
    "$JQ" --argjson keep "$KEEP" '. * $keep' "$SRC" > "$DST"
    ${pkgs.coreutils}/bin/chmod 0644 "$DST"
    # $LIVE is consumed as SRC on the success path, so it must be cleaned up
    # HERE, not only in the failure branch above — otherwise every switch leaves
    # another .settings-merged.<pid> behind in ~/.claude.
    [ -n "''${LIVE:-}" ] && ${pkgs.coreutils}/bin/rm -f "$LIVE"
    echo "[claude-settings] ~/.claude/settings.json written (writable; runtime keys preserved: $KEEP)"
    ) || echo "[claude-settings] subshell failed; HM chain continues"
  '';

  # Auto-update ON, asserted every switch.
  #
  # 2026-08-12: autoUpdates was false, which is why the box sat on 2.1.228 with
  # 2.1.225 and 2.1.227 still on disk beside it — updates were being downloaded
  # into ~/.local/share/claude/versions and never adopted.
  #
  # This key lives in ~/.claude.json, NOT ~/.claude/settings.json, so it cannot
  # ride along with the merged settings above. ~/.claude.json is large mutable
  # runtime state (auth, project history, onboarding flags) and is gitignored,
  # so it is never rewritten wholesale — jq sets the single key and everything
  # else is passed through untouched, via a temp file + atomic mv so an
  # interrupted activation cannot truncate it.
  #
  # installMethod is "native" (~/.local/bin/claude -> versions/<ver>), so the
  # updater actually applies here. Under a nix-managed claude this would be
  # pointless: the store is immutable and the flake pins the version.
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
    MEM_REPO="''${CLAUDE_MEMORY_REPO:-$HOME/git/cloud-data-my-ai-memory}"
    INSTANCE="surface"
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
      echo "[claude-memory] linked into $MEM_REPO (instance: $INSTANCE)"
    fi
  '';

  home.activation.claudeAutoUpdates = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
    JQ="${pkgs.jq}/bin/jq"
    CJ="$HOME/.claude.json"
    [ -f "$CJ" ] || exit 0                 # nothing to patch before first run
    # NOT `.autoUpdates // empty`: jq's // treats false AND null as empty, so an
    # explicitly-disabled autoUpdates reads back as "" and the log then claims
    # it was unset. Ask for the raw value and let `null` mean absent.
    CUR=$("$JQ" -r '.autoUpdates' "$CJ" 2>/dev/null) || exit 0
    [ "$CUR" = "null" ] && CUR="unset"
    if [ "$CUR" != "true" ]; then
      TMP="$CJ.autoupd.$$"
      if "$JQ" '.autoUpdates = true' "$CJ" > "$TMP" 2>/dev/null && [ -s "$TMP" ]; then
        ${pkgs.coreutils}/bin/mv -f "$TMP" "$CJ"
        echo "[claude-autoupdate] autoUpdates: ''${CUR:-unset} -> true"
      else
        ${pkgs.coreutils}/bin/rm -f "$TMP"
        echo "[claude-autoupdate] jq failed; ~/.claude.json left untouched"
      fi
    fi
    ) || echo "[claude-autoupdate] subshell failed; HM chain continues"
  '';

  # NO LOOSE SKILLS. ~/.claude/skills/ must stay empty — every skill ships as a
  # plugin (skill-<name>-plugin) in cloud-marketplace, so it is enabled/disabled
  # declaratively via settings.json enabledPlugins and unloads with its plugin.
  # claude-api now lives in cloud-marketplace/skill-claude-api-plugin (see its
  # ORIGIN.md for the upstream anthropics/skills rev it was vendored from).

  # Register ~/.claude/cloud-marketplace as a plugin marketplace + enable both
  # plugins. `claude plugin marketplace add` is idempotent (re-add of a known
  # path is a no-op / refresh) so this is safe to run every switch — same
  # imperative-but-declared-and-reproducible pattern as installClaudeCode /
  # mcpSecrets below (CLI call from a nix-committed activation block, not an
  # ad-hoc one-liner).
  home.activation.claudeMarketplace = lib.hm.dag.entryAfter [ "claudeSettings" "installClaudeCode" ] ''
    (
    CLAUDE_BIN="$HOME/.local/bin/claude"
    MARKETPLACE_DIR="$HOME/.claude/cloud-marketplace"
    JQ="${pkgs.jq}/bin/jq"
    if [ -x "$CLAUDE_BIN" ] && [ -d "$MARKETPLACE_DIR" ]; then
      $DRY_RUN_CMD "$CLAUDE_BIN" plugin marketplace add "$MARKETPLACE_DIR" >/dev/null 2>&1 || true
      echo "[claude-marketplace] cloud-marketplace registered (enabledPlugins declared in settings.json)"
      # Durable installPath materialization. Claude Code records each installed
      # plugin's installPath as plugins/cache/<marketplace>/<plugin>/<version>
      # and its /plugin loader validates that path — but nothing populates it
      # for a directory-source marketplace, so after a nix store-swap the loader
      # reports "cannot find the hooks". Recreate each installPath as a symlink
      # into the (HM-refreshed, store-backed) marketplace dir. Pointing at the
      # stable ~/.claude/cloud-marketplace/<plugin> path (not the raw store
      # hash) keeps it valid across every rebuild/GC. Data-driven: plugin names
      # from marketplace.json, version from each plugin.json.
      CACHE_DIR="$HOME/.claude/plugins/cache/cloud-marketplace"
      MKT_JSON="$MARKETPLACE_DIR/.claude-plugin/marketplace.json"
      if [ -f "$MKT_JSON" ]; then
        for P in $("$JQ" -r '.plugins[].name' "$MKT_JSON" 2>/dev/null); do
          VER=$("$JQ" -r '.version // "1.0.0"' "$MARKETPLACE_DIR/$P/.claude-plugin/plugin.json" 2>/dev/null || echo "1.0.0")
          DEST="$CACHE_DIR/$P/$VER"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$CACHE_DIR/$P"
          # Replace any real dir left by a prior copy-install; -sfn handles the symlink case.
          [ -e "$DEST" ] && [ ! -L "$DEST" ] && $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -rf "$DEST"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$MARKETPLACE_DIR/$P" "$DEST"
          echo "[claude-marketplace] materialized $P@$VER -> cache installPath"
        done
      fi
    else
      echo "[claude-marketplace] WARNING: claude CLI or marketplace dir not found, skipping"
    fi
    ) || echo "[claude-marketplace] subshell failed; HM chain continues"
  '';

  # Claude Code — direct Bun binary from Anthropic GCS + patchelf for NixOS
  # Auto-updates on every home-manager switch. No npm dependency.
  home.activation.installClaudeCode = lib.hm.dag.entryAfter ["linkGeneration"] ''
    CLAUDE_BIN="$HOME/.local/bin/claude"
    CLAUDE_GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
    ARCH="linux-x64"
    PATCHELF="${pkgs.patchelf}/bin/patchelf"
    INTERPRETER="${pkgs.glibc}/lib/ld-linux-x86-64.so.2"

    mkdir -p "$HOME/.local/bin"

    CURRENT=""
    if [ -x "$CLAUDE_BIN" ]; then
      CURRENT=$("$CLAUDE_BIN" --version 2>/dev/null | head -1 | sed 's/ .*//' || true)
    fi
    LATEST=$(${pkgs.nodejs_22}/bin/npm view @anthropic-ai/claude-code version 2>/dev/null || true)

    if [ -z "$CURRENT" ] || { [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; }; then
      printf "[claude-code] %s → %s (%s)\n" "''${CURRENT:-none}" "$LATEST" "$ARCH"
      # Stage to a temp file then atomic mv. Avoids:
      #   (a) curl error 23 "Failed writing body" when $CLAUDE_BIN is mode 555 (owner has no write bit)
      #   (b) ETXTBSY when $CLAUDE_BIN is currently executing (running claude session)
      # mv replaces the directory entry; the running process keeps its old inode.
      TMP="$CLAUDE_BIN.new.$$"
      # --retry 5 with exponential backoff: tolerate transient GCS errors
      # (curl 56 "Connection reset", 52 "Empty reply", 18 "partial transfer").
      $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fsSL \
        --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 15 \
        "$CLAUDE_GCS/$LATEST/$ARCH/claude" -o "$TMP"
      $DRY_RUN_CMD chmod 755 "$TMP"
      $DRY_RUN_CMD $PATCHELF --set-interpreter "$INTERPRETER" "$TMP"
      $DRY_RUN_CMD chmod 555 "$TMP"
      $DRY_RUN_CMD mv -f "$TMP" "$CLAUDE_BIN"
    else
      printf "[claude-code] %s is up to date\n" "$CURRENT"
    fi

    # Clean up stale npm-global claude if present
    NPM_PKG="$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code"
    NPM_BIN="$HOME/.npm-global/bin/claude"
    if [ -d "$NPM_PKG" ] || [ -L "$NPM_BIN" ]; then
      $DRY_RUN_CMD rm -rf "$NPM_PKG" "$NPM_BIN" || true
    fi
  '';

  # MCP secrets: decrypt secrets.yaml → awk subst ''${VAR} → ~/.mcp.json
  # Mimics Docker env_file + init.sh pattern using awk index() (literal, no regex)
  # Subshell wrap: `exit 0` early-returns (missing files, decrypt failure)
  # must stay local to this block. Bare `exit 0` in HM activations terminates
  # the entire activation script, silently skipping every later activation.
  home.activation.mcpSecrets = lib.hm.dag.entryAfter ["linkGeneration" "claudeAssets"] ''
    (
    SOPS="${pkgs.sops}/bin/sops"
    TPL="$HOME/.claude/mcp.json.tpl"
    SECRETS_YAML="$HOME/.claude/secrets.yaml"
    OUT="$HOME/.mcp.json"
    YQ="${pkgs.yq-go}/bin/yq"
    AWK="${pkgs.gawk}/bin/awk"

    if [ ! -f "$SOPS" ] || [ ! -f "$SECRETS_YAML" ] || [ ! -f "$TPL" ]; then
      echo "[mcp-secrets] WARNING: sops/secrets/template not found, copying template as-is"
      [ -f "$TPL" ] && cp --no-preserve=mode "$TPL" "$OUT"
      exit 0
    fi

    # Decrypt secrets.yaml (same as cloud/ _engine.sh pattern)
    DECRYPTED=$("$SOPS" -d "$SECRETS_YAML" 2>/dev/null) || true
    if [ -z "$DECRYPTED" ]; then
      echo "[mcp-secrets] WARNING: failed to decrypt secrets.yaml"
      cp --no-preserve=mode "$TPL" "$OUT"
      exit 0
    fi

    # Copy template to output (--no-preserve=mode: nix store files are r--, output must be rw-)
    cp --no-preserve=mode "$TPL" "$OUT"

    # Extract ''${VAR} placeholders using awk (no sed, no regex on secrets)
    VARS=$($AWK '{
      s = $0
      while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_-]*\}/)) {
        v = substr(s, RSTART+2, RLENGTH-3)
        print v
        s = substr(s, RSTART+RLENGTH)
      }
    }' "$OUT" | sort -u) || true

    # awk index() substitution — literal string match, no regex
    # Same proven pattern as Authelia init.sh and cloud/ _engine.sh
    for _var in $VARS; do
      _val=$(printf '%s' "$DECRYPTED" | "$YQ" -r ".[\"$_var\"]" 2>/dev/null) || true
      if [ -z "$_val" ] || [ "$_val" = "null" ]; then
        echo "[mcp-secrets] WARNING: $_var not found in secrets — leaving placeholder"
        continue
      fi
      _pat="\''${''${_var}}"
      $AWK -v pat="$_pat" -v rep="$_val" '{
        while (i = index($0, pat)) {
          $0 = substr($0, 1, i-1) rep substr($0, i+length(pat))
        }
        print
      }' "$OUT" > "$OUT.tmp"
      mv "$OUT.tmp" "$OUT"
    done

    chmod 600 "$OUT"
    echo "[mcp-secrets] ~/.mcp.json templated ($(echo $VARS | wc -w) vars substituted)"
    ) || echo "[mcp-secrets] subshell exited non-zero; HM chain continues"
  '';
}
