# home-manager module for da_browser-qute.
#
# Reads four JSON files (settings / search-engines / keybindings / bookmarks)
# and projects them into home-manager's `programs.qutebrowser` declarative
# surface. The JSON files are the SoT — edit them, run home-manager switch,
# qutebrowser config rewrites itself.
#
# Operator integration (in your home.nix):
#
#     imports = [ inputs.da_browser-qute.homeManagerModules.default ];
#     programs.da_browser-qute = {
#       enable = true;
#       defaultBrowser = true;   # set xdg.mime defaults to qutebrowser
#     };

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.da_browser-qute;

  # Resolve JSON config paths relative to this module's directory.
  configsDir = ../2_configs;

  settings        = builtins.fromJSON (builtins.readFile "${configsDir}/qute-settings.json");
  searchEngines   = builtins.fromJSON (builtins.readFile "${configsDir}/qute-search-engines.json");
  keyBindings     = builtins.fromJSON (builtins.readFile "${configsDir}/qute-keybindings.json");

  # qute-bookmarks.json is the SECTION SoT for the dashboard (see src/dashboard).
  # For qutebrowser's flat quickmarks we flatten only the CURATED inline links —
  # a section's direct "links" → "Section/name", and each folder's "links" →
  # "Section/Folder/name" — all pure-eval-safe. Source-driven sections/folders
  # (history / front / cloud:*) carry no inline links here; they're resolved at
  # generate-time by gen-dashboard.sh, so they live only in the dashboard.
  bookmarks       = builtins.fromJSON (builtins.readFile "${configsDir}/qute-bookmarks.json");
  flatQuickmarks  = lib.foldl' (acc: s:
      let
        direct  = lib.mapAttrs' (n: url: lib.nameValuePair "${s.name}/${n}" url) (s.links or {});
        folders = lib.foldl' (a: f:
            a // lib.mapAttrs' (n: url: lib.nameValuePair "${s.name}/${f.name}/${n}" url) (f.links or {})
          ) {} (s.folders or []);
      in acc // direct // folders
    ) {} (bookmarks.sections or []);

  # "New Default Window" / "Open Saved Tabs" — data-driven from
  # qute-default-window.json's tabs[] ({url, pinned}). Opening order fixes
  # each tab's 1-based index; pin commands are appended AFTER all opens using
  # qutebrowser's <count><cmd> glued-prefix syntax (e.g. "1tab-pin" pins tab
  # index 1) so pinning is index-targeted, NOT "pin the current tab" — the
  # latter would silently pin the wrong tab since tabs.background=true opens
  # new tabs unfocused (verified against qutebrowser's tab_pin/_cntwidget
  # source: count is 1-based, count-1 indexes the tab widget directly).
  dwTabsRaw = (builtins.fromJSON (builtins.readFile "${configsDir}/qute-default-window.json")).tabs or [];
  # Tolerate the old plain-string-url schema too (pinned defaults to false).
  dwTabs = map (t: if builtins.isString t then { url = t; pinned = false; } else t) dwTabsRaw;
  pinCmds = lib.concatStringsSep " ;; "
    (lib.filter (c: c != null)
      (lib.imap1 (i: t: if t.pinned or false then "${toString i}tab-pin" else null) dwTabs));
  withPins = openCmds: lib.concatStringsSep " ;; "
    (lib.filter (c: c != "") [ openCmds pinCmds ]);

  defaultWindowCmd = withPins (lib.concatStringsSep " ;; "
    (lib.imap0 (i: t: (if i == 0 then "open -w " else "open -t ") + t.url) dwTabs));

  # "Open Saved Tabs" — reuses the SAME list as the fresh-session/default-window
  # arrangement (qute-default-window.json is the single SoT for "what opens on
  # a fresh session"), but opens every url as a tab in the CURRENT window
  # (no forced new window) — distinct from default_window's Ctrl-Shift-N
  # new-window behavior. On-demand command to recover the saved tab set into
  # whatever window is already focused.
  #
  # Deliberately NOT auto-pinned (unlike default_window): pin-by-index
  # (<N>tab-pin) is only correct in a GUARANTEED-fresh window where opened
  # tabs occupy indices 1..N exactly. open_saved_tabs runs in whatever
  # window is already focused — any pre-existing tabs shift the index of
  # our newly-opened ones, so a blind "1tab-pin ;; 2tab-pin" would pin the
  # WRONG tabs. Use `default_window` (Ctrl-Shift-N) when you want the
  # pinned arrangement guaranteed correct.
  openSavedTabsCmd = lib.concatStringsSep " ;; " (map (t: "open -t " + t.url) dwTabs);

  # "1 Open Last Session Tabs" — restore the auto-saved session (qutebrowser
  # saves `_autosave` on quit when content.auto_save.session is true, which
  # qute-settings.json enables). Distinct from open_saved_tabs (fixed default
  # set): this reopens whatever was actually open last time.
  lastSessionCmd = "session-load _autosave";

  # "Config-shortcuts" — deep-link the dashboard's Shortcuts reference tab. The
  # dashboard JS auto-opens that tab when the URL ends in #shortcuts.
  dashboardHtml = "file:///home/diego/.config/qutebrowser/qute-bookmarks.html";
  configShortcutsCmd = "open ${dashboardHtml}#shortcuts";

  # ── PLUGIN REGISTRY (qute-plugins.json) — see PLAN_plugins-vaultwarden.md ──
  # A 'plugin' is config|userscript|daemon. Config plugins are runtime-
  # toggleable via :config-cycle (ZERO footprint when off) — this is what
  # keeps the browser minimal while still offering Brave-parity features.
  # From the registry we generate, data-driven:
  #   • default settings for each ENABLED config plugin (registry is the SoT
  #     for those leaves — they are intentionally removed from qute-settings.json),
  #   • `:plugin-toggle-<id>` aliases (live :config-cycle, no rebuild),
  #   • keybindings for config plugins that declare one,
  #   • the `:plugins` / `:plugins-vaultwarden` manager-page aliases.
  plugins    = (builtins.fromJSON (builtins.readFile "${configsDir}/qute-plugins.json")).plugins or [];
  cfgPlugins = lib.filter (p: (p.surface or "") == "config" && (p ? option)) plugins;
  # :config-cycle needs literal true/false/enum tokens, not Nix bools.
  vtok = v: if builtins.isBool v then (if v then "true" else "false") else toString v;
  cycleCmd = p: "config-cycle ${p.option} ${vtok p.on_value} ${vtok p.off_value}";
  pluginSettings = lib.foldl' lib.recursiveUpdate {}
    (map (p: lib.setAttrByPath (lib.splitString "." p.option)
              (if (p.enabled or false) then p.on_value else p.off_value)) cfgPlugins);
  pluginToggleAliases = lib.listToAttrs
    (map (p: lib.nameValuePair "plugin-toggle-${p.id}" (cycleCmd p)) cfgPlugins);
  pluginKeybinds = lib.listToAttrs
    (map (p: lib.nameValuePair p.keybinding (cycleCmd p))
      (lib.filter (p: p ? keybinding) cfgPlugins));
  pluginPageAliases = {
    "plugins"             = "open ${dashboardHtml}#plugins";
    "plugins-vaultwarden" = "open ${dashboardHtml}#plugins-vaultwarden";
  };

  # Vaultwarden integration config (build.json::integrations.vaultwarden_bitwarden_cli).
  # build.json lives at the project root, two levels up from src/nix/.
  buildJson = builtins.fromJSON (builtins.readFile ../../build.json);
  vwCfg = buildJson.integrations.vaultwarden_bitwarden_cli or { enabled = false; };

  # Strip ANY leading-underscore key recursively before passing to
  # qutebrowser — by convention every doc/annotation field in our JSON
  # configs starts with "_" (e.g. _description, _comment, _method_options,
  # _flake_modules_dir_note). qutebrowser would otherwise reject them as
  # unknown settings.
  stripDocs = v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: stripDocs) (lib.filterAttrs
        (n: _: ! (lib.hasPrefix "_" n))
        v)
    else if builtins.isList v then map stripDocs v
    else v;

  cleanSettings      = stripDocs settings;
  cleanSearchEngines = stripDocs searchEngines;
  # qute-keybindings.json is now the enriched SoT (key → { cmd, desc, group }).
  # stripDocs drops the _description / _comment_* keys; project each remaining
  # binding object down to its bare `cmd` string for programs.qutebrowser.keyBindings.
  cleanKeyBindings   = lib.mapAttrs
    (_mode: binds: lib.mapAttrs (_k: v: v.cmd) binds)
    (stripDocs keyBindings);
in
{
  options.programs.da_browser-qute = {
    enable = lib.mkEnableOption "da_browser-qute — qutebrowser daily-driver with daemon integrations";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.qutebrowser;
      description = "qutebrowser package. Defaults to nixpkgs.";
    };

    defaultBrowser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set xdg.mime so qutebrowser handles http(s) links by default.";
    };

    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Extra settings merged on top of the JSON-driven config (escape hatch — prefer editing the JSON in src/2_configs/).";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.qutebrowser = {
      enable = true;
      package = cfg.package;
      # base JSON settings, then registry-owned plugin defaults, then operator escape hatch.
      settings = lib.recursiveUpdate (lib.recursiveUpdate cleanSettings pluginSettings) cfg.extraSettings;
      # `default_window` alias (New Default Window). MUST go through the dedicated
      # `aliases` option — it serializes via formatDictLine to
      #   c.aliases['default_window'] = "..."
      # which is valid Python AND the correct qutebrowser API (aliases is a Dict
      # setting). Putting it in `settings` serialized it attribute-style
      # (c.aliases.default-window = ...) — invalid Python (hyphen) and wrong API.
      # Numeric-prefixed aliases sort to the top of the `:` command completion.
      aliases = {
        default_window   = defaultWindowCmd;
        open_saved_tabs  = openSavedTabsCmd;
        "0-default-tabs"   = defaultWindowCmd;    # "0 Open Default Tabs"
        "1-last-session"   = lastSessionCmd;      # "1 Open Last Session Tabs"
        "config-shortcuts" = configShortcutsCmd;  # Shortcuts reference (,s)
      } // pluginPageAliases     # :plugins, :plugins-vaultwarden (manager page)
        // pluginToggleAliases;  # :plugin-toggle-<id> (live :config-cycle)
      searchEngines = cleanSearchEngines;
      # Ctrl-Shift-N → New Default Window; Ctrl-Shift-T → Open Saved Tabs
      # (same list, opened as tabs in the current window instead of a new
      # one); Ctrl-Shift-B → Vaultwarden autofill (qute-bitwarden userscript,
      # ships bundled with qutebrowser — see build.json::integrations).
      # ONE merged `normal` set. NB: `//` between two attrsets that BOTH have a
      # `normal` key is SHALLOW — it replaces the whole set, not merges it. The
      # previous form (`{normal=…} // optionalAttrs {normal.<C-S-b>=…}`) silently
      # dropped every other normal bind whenever vaultwarden was enabled. Merge
      # all leaf keys into a single `normal` instead, then recursiveUpdate onto
      # the JSON binds (cleanKeyBindings) which is a proper deep merge.
      keyBindings = lib.recursiveUpdate cleanKeyBindings {
        normal = {
          "<Ctrl-Shift-n>" = "default_window";
          "<Ctrl-Shift-t>" = "open_saved_tabs";
          ",pp"            = "plugins";   # open the Plugins manager page
        }
        // pluginKeybinds   # ,pa ,pj ,pd ,pf ,pm — live config-plugin toggles
        // lib.optionalAttrs (vwCfg.enabled or false) {
             "<Ctrl-Shift-b>" = "spawn --userscript qute-bitwarden --totp";
           };
      };
      quickmarks = flatQuickmarks;
    };

    home.packages = lib.optionals (vwCfg.enabled or false) [ pkgs.bitwarden-cli pkgs.keyutils ];

    # `bw config server <url>` is idempotent and carries no secret — safe to
    # run declaratively on every activation. The actual `bw login` (needs the
    # master password) is a ONE-TIME MANUAL step; it cannot be automated
    # here without storing a credential outside sops, which we don't do.
    home.activation.bwVaultwardenServer = lib.mkIf (vwCfg.enabled or false)
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${pkgs.bitwarden-cli}/bin/bw config server ${lib.escapeShellArg vwCfg.server_url} >/dev/null 2>&1 || true
      '');

    # Bookmark dashboard start page — generated (gen-dashboard.sh) into dist/,
    # committed, installed here. qute-settings.json points url.start_pages +
    # url.default_page at this file.
    xdg.configFile."qutebrowser/qute-bookmarks.html".source = ../../dist/qute-bookmarks.html;

    # Native qutebrowser Bookmarks (the built-in :bookmark-list) — the FULL list
    # (curated + cloud-resolved), generated by gen-dashboard.sh into dist/ so it
    # matches the dashboard exactly. quickmarks above only carry the curated
    # folders (cloud:* can't be resolved in pure eval); this file carries all.
    xdg.configFile."qutebrowser/bookmarks/urls".source = ../../dist/qute-bookmarks-urls;

    xdg.mimeApps = lib.mkIf cfg.defaultBrowser {
      enable = true;
      defaultApplications = {
        "text/html"             = "org.qutebrowser.qutebrowser.desktop";
        "x-scheme-handler/http"  = "org.qutebrowser.qutebrowser.desktop";
        "x-scheme-handler/https" = "org.qutebrowser.qutebrowser.desktop";
        "x-scheme-handler/about" = "org.qutebrowser.qutebrowser.desktop";
        "x-scheme-handler/unknown" = "org.qutebrowser.qutebrowser.desktop";
      };
    };
  };
}
