# System Protection — Orphan Reaper (declarative deployment)
#
# Deploys the orphan-reaper engine + whitelist to stable user paths so it can
# be run on demand without restart:
#
#   ~/.local/bin/orphan-reaper                     ← engine on $PATH
#   ~/.config/orphan-reaper/whitelist.json         ← data-driven rules
#
# Why this exists: long-running KDE sessions accumulate leaked watchers
# (esbuild --watch=forever from build.sh dev, abandoned background jobs,
# ghost cgroup children of closed konsoles, etc.) — all reparented to
# user-systemd with no controlling tty. Without a whitelist, "kill all
# user orphans" would also kill kwin/plasmashell/pipewire (also reparented
# to user-systemd by design). The JSON whitelist solves that declaratively.
#
# Defaults to --dry-run (safe to run any time; only --apply signals).
#
# Source files:
#   ./system-protection-orphan-reaper.sh    — engine
#   ./system-protection-orphan-reaper.json  — whitelist (source of truth)
#   ./test-system-protection-orphan-reaper.sh — tester
#
# Imported by: system-protection.nix (orchestrator)
#
{ config, pkgs, lib, ... }:

let
  whitelistPath = ./system-protection-orphan-reaper.json;
  enginePath    = ./system-protection-orphan-reaper.sh;

  # Wrapper that points the engine at the deployed whitelist by default.
  # User can still override via --whitelist or WHITELIST_JSON= env.
  reaperWrapper = pkgs.writeShellScriptBin "orphan-reaper"
    (builtins.replaceStrings [ "@enginePath@" ] [ (toString enginePath) ]
      (builtins.readFile ./scripts/orphan-reaper.sh));
in
{
  home.packages = [
    pkgs.jq
    reaperWrapper
  ];

  home.file = {
    # Whitelist at stable, user-editable path
    ".config/orphan-reaper/whitelist.json".source = whitelistPath;

    # Raw engine also linked, in case the user wants to invoke it directly
    ".local/share/system-protection/orphan-reaper-engine.sh".source = enginePath;
  };

  # ── Desktop entry for launcher ──
  xdg.desktopEntries.orphan-reaper = {
    name = "Orphan Reaper";
    comment = "Clean up orphaned processes (dry-run mode)";
    exec = "orphan-reaper";
    icon = "utilities-process";
    terminal = true;
    categories = [ "System" "Utility" ];
  };
}
