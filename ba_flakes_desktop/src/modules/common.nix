# Common configuration shared by all hosts
{ config, pkgs, lib, ... }:

let
  # Every home-manager-managed target, one relative path per line. Shared by
  # the two backup passes below and by unfreezeHmFiles, so all three agree on
  # exactly which paths are ours to touch.
  _writableTargets = pkgs.writeText "hm-writable-targets"
    (lib.concatMapStringsSep "\n" (f: f.target) (lib.attrValues config.home.file));

  # Shell helper shared by both backup passes. A backup is OURS -- and so pure
  # noise, safe to drop -- when its bytes match what the live file holds or
  # what some home-manager generation put at that path. A real local edit
  # matches none of them and is always kept.
  #
  # Scanning generations, not just $oldGenPath, is the point: unfreeze's copy
  # of generation N-1 gets backed up during switch N, so by the time anything
  # notices, the backup is already two generations behind and a single
  # old-gen comparison says "modified" for every file whose store content
  # moves each switch. That is what wedged the last switch.
  #
  # ponytail: 20 newest generations, newest-first, first hit wins. A backup
  # older than that is left alone and home-manager's own abort fires with its
  # own clear message -- the right outcome for something we cannot vouch for.
  _bakIsOursFn = ''
    _hm_backup_is_ours() {
      local bak="$1" live="$2" rel="$3" g t
      if [ -e "$live" ] && ${pkgs.diffutils}/bin/diff -rq "$bak" "$live" >/dev/null 2>&1; then
        return 0
      fi
      for g in $(${pkgs.coreutils}/bin/ls -d \
                   "$HOME/.local/state/nix/profiles"/home-manager-*-link 2>/dev/null \
                 | ${pkgs.coreutils}/bin/sort -V | ${pkgs.coreutils}/bin/tail -20 \
                 | ${pkgs.coreutils}/bin/tac); do
        t="$(${pkgs.coreutils}/bin/readlink -f "$g")/home-files/$rel"
        [ -e "$t" ] || continue
        if ${pkgs.diffutils}/bin/diff -rq "$bak" "$t" >/dev/null 2>&1; then
          return 0
        fi
      done
      return 1
    }
  '';
in
{
  imports = [
    ./programs/shells/bash.nix
    ./programs/shells/zsh.nix
    ./programs/shells/fish.nix
    ./programs/shells/starship.nix
    ./programs/shells/fzf.nix
    ./my-webserver
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
    (pkgs.callPackage ../pkgs/goose.nix {})       # cloud-ai-cli (MCP-native AI agent)
    (pkgs.callPackage ../pkgs/goose-desktop.nix {}) # goose desktop UI (Electron)
    pkgs.zstd  # used by build.sh (nar.zst import + per-path GHCR nix cache decompress)
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
    # Every XDG user dir lives under ~/others so the home root stays clean.
    # publicShare/templates MUST be listed explicitly: their option defaults
    # are $HOME/Public and $HOME/Templates, and createDirectories mkdir -p's
    # the defaults too — leaving them out is what kept recreating those two.
    userDirs = {
      enable = true;
      createDirectories = true;
      desktop = "${config.home.homeDirectory}/others/Desktop";
      documents = "${config.home.homeDirectory}/others/Documents";
      download = "${config.home.homeDirectory}/others/Downloads";
      music = "${config.home.homeDirectory}/others/Music";
      pictures = "${config.home.homeDirectory}/others/Pictures";
      publicShare = "${config.home.homeDirectory}/others/Public";
      templates = "${config.home.homeDirectory}/others/Templates";
      videos = "${config.home.homeDirectory}/others/Videos";
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

    # Authelia OIDC — paths to vault credentials + tokens
    AUTHELIA_OIDC_CREDENTIALS_DIR = "$HOME/git/cloud-vault/A0_keys/providers/authelia/signed-bearer_jwt/credentials";
    AUTHELIA_OIDC_TOKENS_DIR = "$HOME/git/cloud-vault/A0_keys/providers/authelia/signed-bearer_jwt/tokens";
    AUTHELIA_OIDC_CLIENT_ID = "claude-admin";
    AUTHELIA_TOKEN_URL = "https://auth.diegonmarcos.com/api/oidc/token";
  };

  # Session path additions
  # NOTE: These are appended to PATH in hm-session-vars.fish on login.
  # For interactive fish shells, fish.nix also calls fish_add_path (idempotent)
  # to ensure paths are available even when __HM_SESS_VARS_SOURCED is inherited.
  home.sessionPath = [
    # Must precede /run/current-system/sw/bin so `sudo` resolves to the setuid
    # wrapper. /etc/set-environment prepends it, but that file is guarded against
    # re-running, so login shells inherit a PATH where sw/bin has taken the lead.
    "/run/wrappers/bin"
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

  # Disable man-page cache generation (mandb). Some upstream man pages (fish,
  # ranger, openssl, peek) have formatting that mandb can't parse, causing the
  # man-cache.drv build to fail. This only affects `apropos` / `man -k` keyword
  # searches — man pages themselves are still available via `man <page>`.
  programs.man.generateCaches = false;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Systemd user services (for Linux)
  systemd.user.startServices = "sd-switch";

  # Web server: my-webserver (JSON/YAML tables + Markdown +
  # Eruda DevTools). Module imported above → deploys the
  # my-webserver wrapper around a prebuilt, per-arch fetched
  # binary. Auto-started via systemd.user.services (port 8000).

  # News notifications
  news.display = "silent";

  # nix-drift — version drift detection, runs post-switch
  home.file.".local/bin/nix-drift" = {
    source = ./dotfiles/nix-drift.sh;
    executable = true;
  };


  # ── Writable dotfiles ─────────────────────────────────────────────────────
  # Make every HM-delivered file WRITABLE for imperative testing. HM symlinks
  # each managed file read-only into the nix store; right after linkGeneration
  # we swap each store symlink for a writable copy of the same content. The next
  # switch's linkGeneration re-establishes the store symlink (declarative ALWAYS
  # wins) and this re-copies — so deployed files are always editable between
  # switches yet never diverge from source across one. Data-driven: the target
  # list is derived from config.home.file (xdg.configFile feeds into it), so
  # every managed file is covered with zero per-file wiring. Only store-backed
  # symlinks are touched (out-of-store symlinks are left as-is).
  # check-link-targets runs BEFORE linkGeneration and ABORTS activation when a
  # backup is already sitting where it would write a new one. unfreezeHmFiles'
  # pruner runs after linkGeneration, so it can never clear a backup that
  # blocks that pre-flight -- one stale file wedges every `-b <ext>` switch
  # permanently, which is exactly what happened. Prune first, on the same
  # "is this still ours" test, so a leftover from an older generation cannot
  # deadlock the switch. A backup we cannot prove is ours is left alone and
  # home-manager's own abort still fires, with its own clear message.
  home.activation.pruneStaleHmBackups =
    lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      ${_bakIsOursFn}
      if [ -n "''${HOME_MANAGER_BACKUP_EXT:-}" ]; then
        while IFS= read -r _rel; do
          [ -n "$_rel" ] || continue
          _bak="$HOME/$_rel.$HOME_MANAGER_BACKUP_EXT"
          [ -e "$_bak" ] || continue
          if _hm_backup_is_ours "$_bak" "$HOME/$_rel" "$_rel"; then
            $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -rf "$_bak"
          fi
        done < ${_writableTargets}
      fi
    '';

  home.activation.unfreezeHmFiles =
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      ${_bakIsOursFn}
      while IFS= read -r _rel; do
        [ -n "$_rel" ] || continue
        _t="$HOME/$_rel"
        [ -L "$_t" ] || continue
        _r="$(${pkgs.coreutils}/bin/readlink -f "$_t" 2>/dev/null)"
        [ -n "$_r" ] && [ -e "$_r" ] || continue
        case "$_r" in /nix/store/*) ;; *) continue ;; esac
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$_t"
        # -R, NOT -RL. `$_r` is already the resolved real path, so -L bought
        # nothing at the top level while forcing every symlink INSIDE a copied
        # directory to be dereferenced too. ~/.config/fish/completions is a tree
        # of links into per-package completion derivations; when one of those
        # (openssl-*-fish-completions) is not in the closure, cp -RL fails with
        # "cannot stat", and one missing completion file aborted the ENTIRE
        # home-manager activation. Copying links as links makes a dangling entry
        # cost exactly one dangling entry.
        if ! $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -R "$_r" "$_t"; then
          # Never fatal: this step exists to make files editable, so failing to
          # unfreeze one is a warning, not a reason to abandon the generation.
          echo "[unfreeze] WARNING: could not copy $_r -> $_t (leaving store symlink)"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "$_r" "$_t" || true
          continue
        fi
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod -R u+w "$_t" || true
        # Drop the backup linkGeneration just made when it is one of ours.
        # Unfreeze guarantees every managed path is a real file, so the NEXT
        # switch finds all of them "in the way" and backs them up again -- an
        # ever-growing pile that eventually fails activation outright with
        # "would be clobbered by backing up", which is why each switch needed a
        # fresh -b suffix. pruneStaleHmBackups clears the inherited pile before
        # the pre-flight check; this keeps the steady state clean.
        _bak="$_t.''${HOME_MANAGER_BACKUP_EXT:-}"
        if [ -n "''${HOME_MANAGER_BACKUP_EXT:-}" ] && [ -e "$_bak" ] \
           && _hm_backup_is_ours "$_bak" "$_t" "$_rel"; then
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -rf "$_bak"
        fi
      done < ${_writableTargets}
    '';

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
