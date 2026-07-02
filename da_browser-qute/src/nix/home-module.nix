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

  # qute-bookmarks.json is the FOLDER SoT for the dashboard (see src/dashboard).
  # For qutebrowser's flat quickmarks we flatten the CURATED folders (those with
  # inline "links") into "Folder/name" keys — pure-eval-safe. The cloud folders
  # (source:"cloud:*") are resolved at generate-time by gen-dashboard.sh from
  # cloud-data, so they live only in the dashboard, not in quickmarks.
  bookmarks       = builtins.fromJSON (builtins.readFile "${configsDir}/qute-bookmarks.json");
  curatedFolders  = builtins.filter (f: f ? links) (bookmarks.folders or []);
  flatQuickmarks  = lib.foldl' (acc: f:
      acc // (lib.mapAttrs' (n: url: lib.nameValuePair "${f.name}/${n}" url) f.links)
    ) {} curatedFolders;

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
  cleanKeyBindings   = stripDocs keyBindings;
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
      settings = lib.recursiveUpdate cleanSettings cfg.extraSettings;
      searchEngines = cleanSearchEngines;
      keyBindings = cleanKeyBindings;
      quickmarks = flatQuickmarks;
    };

    # Bookmark dashboard start page — generated (gen-dashboard.sh) into dist/,
    # committed, installed here. qute-settings.json points url.start_pages +
    # url.default_page at this file.
    xdg.configFile."qutebrowser/dashboard.html".source = ../../dist/dashboard.html;

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
