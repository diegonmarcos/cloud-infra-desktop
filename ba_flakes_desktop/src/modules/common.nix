# Common configuration shared by all hosts
{ config, pkgs, lib, ... }:

{
  imports = [
    ./programs/shells/bash.nix
    ./programs/shells/zsh.nix
    ./programs/shells/fish.nix
    ./programs/shells/starship.nix
    ./programs/shells/fzf.nix
    ./web-server-md-eruda.nix
    ./cliphist.nix
    ./programs/editors/vim.nix
    ./programs/git.nix
    ./programs/tmux.nix
    ./programs/mesh.nix
    ./programs/connect.nix
    # browsers-gpu.nix is now a NIXPKGS OVERLAY (wired in src/flake.nix),
    # not a home-manager module. No import needed here.
  ];

  # Enable Home Manager
  programs.home-manager.enable = true;

  # Packages needed by MCP servers (all profiles)
  home.packages = [
    (pkgs.callPackage ../pkgs/octocode.nix {})  # code-graph-context MCP
    (pkgs.callPackage ../pkgs/goose.nix {})      # cloud-ai-cli (MCP-native AI agent)
  ];

  # Nix settings
  nix = {
    package = pkgs.nix;
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      warn-dirty = false;
      auto-optimise-store = true;
    };
    # Automatic garbage collection
    gc = {
      automatic = true;
      frequency = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  # XDG Base Directory compliance
  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      desktop = "${config.home.homeDirectory}/Desktop";
      documents = "${config.home.homeDirectory}/Documents";
      download = "${config.home.homeDirectory}/Downloads";
      music = "${config.home.homeDirectory}/Music";
      pictures = "${config.home.homeDirectory}/Pictures";
      videos = "${config.home.homeDirectory}/Videos";
    };
  };

  # Session variables
  home.sessionVariables = {
    EDITOR = "vim";
    VISUAL = "vim";
    PAGER = "less";
    MANPAGER = "less -R";

    # Locale — en_DK.UTF-8 = ISO 8601 date (YYYY-MM-DD, dashes) + 24h time.
    # Same English vocabulary as en_US/en_GB; only date+time formats differ.
    # 2026-04-28 changed from en_US.UTF-8 (which gave AM/PM + MM/DD/YYYY).
    # Sibling: home.file.".config/plasma-localerc" below — KDE Plasma 6 reads
    # its own [Formats] file at runtime; without it Dolphin/Konsole/clock all
    # fall back to en_US even with LC_ALL set.
    LANG = "en_DK.UTF-8";
    LC_ALL = "en_DK.UTF-8";

    # Less options
    LESS = "-R -F -X";

    # Colored man pages
    LESS_TERMCAP_mb = "$(printf '\\e[1;31m')";
    LESS_TERMCAP_md = "$(printf '\\e[1;36m')";
    LESS_TERMCAP_me = "$(printf '\\e[0m')";
    LESS_TERMCAP_se = "$(printf '\\e[0m')";
    LESS_TERMCAP_so = "$(printf '\\e[1;44;33m')";
    LESS_TERMCAP_ue = "$(printf '\\e[0m')";
    LESS_TERMCAP_us = "$(printf '\\e[1;32m')";

    # Octocode — OpenAI-compatible endpoint (Ollama on oci-apps)
    OPENAI_BASE_URL = "http://10.0.0.6:11435/v1";
    OPENAI_API_KEY = "sk-dummy";

    # Authelia OIDC — paths to vault credentials + tokens
    AUTHELIA_OIDC_CREDENTIALS_DIR = "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/credentials";
    AUTHELIA_OIDC_TOKENS_DIR = "$HOME/git/vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens";
    AUTHELIA_OIDC_CLIENT_ID = "claude-admin";
    AUTHELIA_TOKEN_URL = "https://auth.diegonmarcos.com/api/oidc/token";
  };

  # Session path additions
  # NOTE: These are appended to PATH in hm-session-vars.fish on login.
  # For interactive fish shells, fish.nix also calls fish_add_path (idempotent)
  # to ensure paths are available even when __HM_SESS_VARS_SOURCED is inherited.
  home.sessionPath = [
    # Shared tools (previously in OS environment.sessionVariables.PATH)
    "/mnt/shared/tools/base/bin"
    "/mnt/shared/tools/dev/bin"
    "/mnt/shared/tools/data/bin"
    "/mnt/shared/tools/devops/bin"
    "/mnt/shared/tools/scripts"
    # User-local tools
    "$HOME/.local/bin"
    "$HOME/.cargo/bin"
    "$HOME/.npm-global/bin"
    "$HOME/go/bin"
    "$HOME/.nix-profile/bin"
  ];

  # Font configuration
  fonts.fontconfig.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Systemd user services (for Linux)
  systemd.user.startServices = "sd-switch";

  # Web server: web-server-md-eruda (Node.js, Markdown + Eruda DevTools)
  # Module imported above → deploys http-dev + web-server-md-eruda.mjs
  # Auto-started in fish interactiveShellInit (port 8000)

  # News notifications
  news.display = "silent";

  # nix-drift — version drift detection, runs post-switch
  home.file.".local/bin/nix-drift" = {
    source = ./dotfiles/nix-drift.sh;
    executable = true;
  };

  # Claude Code configuration + MCP server config
  # CLAUDE.md is generated dynamically from template + cloud-data at activation time
  home.file.".claude/CLAUDE.md.tpl".source = ./dotfiles/claude/CLAUDE.md.tpl;
  home.file.".claude/gen-claude-md.sh" = {
    source = ./dotfiles/claude/gen-claude-md.sh;
    executable = true;
  };
  home.file.".claude/mcp.json.tpl".source = ./dotfiles/claude/mcp.json.tpl;
  home.file.".claude/secrets.yaml".source = ./dotfiles/claude/secrets.yaml;
  home.file.".claude/statusline-command.sh" = {
    source = ./dotfiles/claude/statusline-command.sh;
    executable = true;
  };
  # Plugin/MCP status for the statusline + claude-superset banner (data-driven).
  home.file.".claude/claude-plugins.json".source = ./dotfiles/claude/claude-plugins.json;
  home.file.".claude/claude-plugins-status.sh" = {
    source = ./dotfiles/claude/claude-plugins-status.sh;
    executable = true;
  };
  home.file.".claude/claude-mcp-status.sh" = {
    source = ./dotfiles/claude/claude-mcp-status.sh;
    executable = true;
  };
  # Tier-based Claude Code hooks (renamed 2026-05-07 from claude-memory /
  # declarative-guard / pretool-guard for clearer event-tier mapping).
  #   a-* → SessionStart       (one-shot context injection)
  #   b-* → UserPromptSubmit   (per-prompt context injection)
  #   c-* → PreToolUse(Bash)   (split into blockers + warnings)
  home.file.".claude/hooks/a-context-inject-memory.sh" = {
    source = ./dotfiles/claude/a-context-inject-memory.sh;
    executable = true;
  };
  home.file.".claude/hooks/b-context-inject-prompt.sh" = {
    source = ./dotfiles/claude/b-context-inject-prompt.sh;
    executable = true;
  };
  home.file.".claude/hooks/c-context-inject-pretool.sh" = {
    source = ./dotfiles/claude/c-context-inject-pretool.sh;
    executable = true;
  };
  home.file.".claude/hooks/c-pretool-guard-blockers.sh" = {
    source = ./dotfiles/claude/c-pretool-guard-blockers.sh;
    executable = true;
  };
  home.file.".claude/hooks/c-pretool-guard-warning.sh" = {
    source = ./dotfiles/claude/c-pretool-guard-warning.sh;
    executable = true;
  };
  home.file.".claude/settings.json".source = ./dotfiles/claude/settings.json;

  # claude-api skill — pinned from anthropics/skills repo. Symlinks the whole
  # directory (SKILL.md + per-language assets) so updates are a single
  # rev/hash bump. https://github.com/anthropics/skills
  home.file.".claude/skills/claude-api".source =
    let anthropicSkills = pkgs.fetchFromGitHub {
      owner = "anthropics";
      repo  = "skills";
      rev   = "da20c92503b2e8ff1cf28ca81a0df4673debdbf7";
      sha256 = "08b3g2y0dx02bg5ypi8yvsd10dc19j9zm811hqq50aymbq8ny9h6";
    };
    in "${anthropicSkills}/skills/claude-api";

  # ponytail — "lazy senior dev" skill (vendored, owned copy from
  # DietrichGebert/ponytail @ 6da37bf, MIT). Wired declaratively, NOT via the
  # plugin marketplace (settings-only local-marketplace activation is not
  # guaranteed by Claude Code docs):
  #   - the self-contained dir keeps hooks/ beside skills/ so the hook JS resolves
  #     its relative requires and reads ../skills/ponytail/SKILL.md;
  #   - each SKILL.md is also exposed under .claude/skills/ to auto-load as /ponytail*.
  # SessionStart + UserPromptSubmit activation hooks are registered in settings.json.
  home.file.".claude/ponytail".source = ./dotfiles/claude/ponytail;
  home.file.".claude/skills/ponytail".source = ./dotfiles/claude/ponytail/skills/ponytail;
  home.file.".claude/skills/ponytail-review".source = ./dotfiles/claude/ponytail/skills/ponytail-review;
  home.file.".claude/skills/ponytail-audit".source = ./dotfiles/claude/ponytail/skills/ponytail-audit;
  home.file.".claude/skills/ponytail-debt".source = ./dotfiles/claude/ponytail/skills/ponytail-debt;
  home.file.".claude/skills/ponytail-gain".source = ./dotfiles/claude/ponytail/skills/ponytail-gain;
  home.file.".claude/skills/ponytail-help".source = ./dotfiles/claude/ponytail/skills/ponytail-help;

  home.file.".rgignore".source = ./dotfiles/claude/rgignore;

  # Goose AI CLI configuration (cloud-ai-cli alias)
  # NOTE: Goose can't follow Nix store symlinks, so we copy instead of symlink
  home.activation.gooseConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.config/goose"
    rm -f "$HOME/.config/goose/config.yaml"
    cp ${./dotfiles/goose/config.yaml} "$HOME/.config/goose/config.yaml"
    chmod 644 "$HOME/.config/goose/config.yaml"
  '';

  # Gemini CLI configuration + MCP server config
  # Uses the same sops secret substitution as Claude's mcp.json
  home.file.".gemini/settings.json.tpl".source = ./dotfiles/gemini/settings.json.tpl;

  # Minimal .gitignore so $HOME is a git repo (ignore everything)
  # This makes Claude Code use `git ls-files` (instant) instead of ripgrep (97s timeout)
  home.file.".gitignore".text = "*";

  # Initialize $HOME as minimal git repo so Claude Code uses git ls-files (instant)
  # instead of ripgrep fallback (97s timeout scanning all of $HOME)
  home.activation.initHomeGit = lib.hm.dag.entryAfter ["linkGeneration"] ''
    if [ ! -d "$HOME/.git" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git init "$HOME" 2>/dev/null
    fi
    # Ensure .gitignore is tracked (it's a nix-managed symlink)
    $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$HOME" add -f .gitignore 2>/dev/null || true
  '';

  # Global tsx (TypeScript runner)
  home.activation.globalTsx = lib.hm.dag.entryAfter ["linkGeneration"] ''
    PATH="${pkgs.nodejs_20}/bin:$PATH"
    if ! command -v tsx >/dev/null 2>&1; then
      $DRY_RUN_CMD ${pkgs.nodejs_20}/bin/npm install -g tsx --no-audit --no-fund || true
    fi
  '';

  # HM always wins — remove imperative nix profile packages that conflict
  home.activation.removeImperativePackages = lib.hm.dag.entryBefore ["installPackages"] ''
    if command -v nix >/dev/null 2>&1 && nix profile list >/dev/null 2>&1; then
      for pkg in $(nix profile list 2>/dev/null | grep "^Name:" | sed 's/.*Name:[[:space:]]*//' | sed 's/\x1b\[[0-9;]*m//g'); do
        echo "[hm] Removing imperative nix profile package: $pkg"
        nix profile remove "$pkg" 2>/dev/null || true
      done
    fi
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
  home.activation.mcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
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

  # Gemini CLI: decrypt secrets.yaml → awk subst ''${VAR} → ~/.gemini/settings.json
  # Same pattern as Claude's mcpSecrets, but outputs to Gemini's settings.json
  # Subshell wrap: same rationale as mcpSecrets above — `exit 0` from inside
  # the body must NOT propagate to the parent HM activation script.
  home.activation.geminiMcpSecrets = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    SOPS="${pkgs.sops}/bin/sops"
    TPL="$HOME/.gemini/settings.json.tpl"
    SECRETS_YAML="$HOME/.claude/secrets.yaml"
    OUT="$HOME/.gemini/settings.json"
    YQ="${pkgs.yq-go}/bin/yq"
    AWK="${pkgs.gawk}/bin/awk"

    if [ ! -f "$SOPS" ] || [ ! -f "$SECRETS_YAML" ] || [ ! -f "$TPL" ]; then
      echo "[gemini-mcp] WARNING: sops/secrets/template not found, copying template as-is"
      [ -f "$TPL" ] && cp --no-preserve=mode "$TPL" "$OUT"
      exit 0
    fi

    DECRYPTED=$("$SOPS" -d "$SECRETS_YAML" 2>/dev/null) || true
    if [ -z "$DECRYPTED" ]; then
      echo "[gemini-mcp] WARNING: failed to decrypt secrets.yaml"
      cp --no-preserve=mode "$TPL" "$OUT"
      exit 0
    fi

    cp --no-preserve=mode "$TPL" "$OUT"

    VARS=$($AWK '{
      s = $0
      while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_-]*\}/)) {
        v = substr(s, RSTART+2, RLENGTH-3)
        print v
        s = substr(s, RSTART+RLENGTH)
      }
    }' "$OUT" | sort -u) || true

    for _var in $VARS; do
      _val=$(printf '%s' "$DECRYPTED" | "$YQ" -r ".[\"$_var\"]" 2>/dev/null) || true
      if [ -z "$_val" ] || [ "$_val" = "null" ]; then
        echo "[gemini-mcp] WARNING: $_var not found in secrets — leaving placeholder"
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
    echo "[gemini-mcp] ~/.gemini/settings.json templated ($(echo $VARS | wc -w) vars substituted)"
    ) || echo "[gemini-mcp] subshell exited non-zero; HM chain continues"
  '';

  # Generate CLAUDE.md from template + cloud-data (dynamic VM/service tables)
  home.activation.genClaudeMd = lib.hm.dag.entryAfter ["linkGeneration"] ''
    GEN="$HOME/.claude/gen-claude-md.sh"
    if [ -x "$GEN" ]; then
      # gen-claude-md.sh uses awk + find + sort + date — HM activations have
      # only a minimal PATH, so binaries must be put on PATH explicitly.
      PATH="${pkgs.gawk}/bin:${pkgs.findutils}/bin:${pkgs.coreutils}/bin:$PATH" \
      NODE_BIN="${pkgs.nodejs_20}/bin/node" \
        $DRY_RUN_CMD "$GEN" \
          "$HOME/.claude/CLAUDE.md.tpl" \
          "$HOME/.claude/CLAUDE.md" \
          "$HOME/git/cloud/cloud-data" \
        || echo "[gen-claude-md] WARNING: generation failed, template used as fallback"
    else
      echo "[gen-claude-md] WARNING: gen-claude-md.sh not found"
    fi
  '';

  # KDE Plasma 6 [Formats] override — plasma-manager / Dolphin / Konsole /
  # the panel clock read this file directly, ignoring LC_TIME from the
  # environment. Aligned with home.sessionVariables.LC_ALL above.
  # 2026-04-28: previously declared in home-manager/home.nix which is NOT
  # imported by any host — declaration silently ignored. Moved here so it
  # actually lands. `-b backup` (build.sh:319) handles existing-file
  # conflicts at switch time; no per-file `force` needed.
  home.file.".config/plasma-localerc".text = ''
    [Formats]
    LANG=en_DK.UTF-8
    LC_TIME=en_DK.UTF-8
    LC_MEASUREMENT=en_DK.UTF-8
    LC_MONETARY=en_DK.UTF-8
    LC_NUMERIC=en_DK.UTF-8
  '';
}
