# Brave browser — DEDICATED declarative module.
# Single source of truth for everything Brave-related on this host.
#
#   Package           pkgs.unstable.brave + a separate GPU-wrapped variant
#                     (browsers-gpu.nix). Both installed side-by-side.
#
#   Profile dirs      INDEPENDENT, NOT symlinked.
#                     - brave        → ~/.config/BraveSoftware/Brave-Browser/
#                     - brave-gpu    → ~/.config/BraveSoftware/Brave-Browser-GPU/
#                     Each has its own Default/, SingletonLock, etc. → both
#                     can run simultaneously without LevelDB lock conflicts.
#
#   Declared configs  WRITTEN TO BOTH dirs by home-manager:
#                     - External Extensions/<id>.json (force-install)
#                       Source of truth: ./brave-extensions.json
#                     - policies/managed/<file>.json
#                       Defined inline below.
#                     Result: same extensions + same policies on both
#                     variants. Login state, bookmarks, cookies, history
#                     stay per-variant (you log in to brave-gpu separately
#                     once — it persists from then on).
#
# Why no symlink for Default/: Brave's per-database LevelDB locks
# (Default/<dir>/LOCK files) are filesystem-level. Two processes pointing
# at the same physical Default/ via symlink → "Something went wrong when
# opening your profile" because lock acquisition fails for the second
# process. Independent profiles + duplicated declarative configs is the
# only design that allows concurrent use.
#
# Imported by: modules/profiles/7-productivity.nix
#
{ config, pkgs, lib, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ./brave-extensions.json);

  gpuLib = import ./browsers-gpu.nix { inherit pkgs lib; };
  braveGpu = gpuLib.mkGpuVariant "brave" pkgs.unstable.brave;

  # Both profile dirs — each variant gets its own. Configs below are
  # generated for BOTH so they stay in sync declaratively.
  profileDirs = [
    ".config/BraveSoftware/Brave-Browser"      # original brave
    ".config/BraveSoftware/Brave-Browser-GPU"  # brave-gpu (matches userDataDir in browsers-gpu.json)
  ];

  # Force-install JSON for one extension in one profile dir.
  mkExtensionFile = dir: id: _meta: lib.nameValuePair
    "${dir}/External Extensions/${id}.json"
    { text = builtins.toJSON {
        external_update_url = "https://clients2.google.com/service/update2/crx";
      };
    };

  # Inline policy definitions — converted to per-dir JSON files below.
  policyDefinitions = {
    "homepage-localhost-8000" = {
      # 4 = "Open a list of URLs"
      RestoreOnStartup = 4;
      RestoreOnStartupURLs = [ "http://localhost:8000" ];
      HomepageLocation = "http://localhost:8000";
      HomepageIsNewTabPage = false;
      ShowHomeButton = true;
      NewTabPageLocation = "http://localhost:8000";
    };
  };

  mkPolicyFile = dir: name: content: lib.nameValuePair
    "${dir}/policies/managed/${name}.json"
    { text = builtins.toJSON content; };

  # For each profile dir, generate the full set of extension + policy
  # files. Concatenate everything into one big home.file attrset.
  filesPerDir = dir:
    (lib.mapAttrs' (mkExtensionFile dir) cfg.extensions) //
    (lib.mapAttrs' (mkPolicyFile dir) policyDefinitions);

  allFiles = lib.foldl (acc: dir: acc // (filesPerDir dir)) {} profileDirs;
in
{
  programs.chromium = {
    enable = true;
    package = pkgs.unstable.brave;  # untouched original
  };

  # GPU-wrapped variant — KDE app menu / KRunner show TWO Brave entries.
  # Same flags, same extensions, same homepage. Different profile dirs
  # (independent runtime state) → both runnable at once.
  home.packages = [ braveGpu ];

  # Declarative configs duplicated to BOTH profile dirs.
  home.file = allFiles;

  # Cleanup: remove any leftover symlinks from the previous symlink-based
  # design (Default → ../Brave-Browser/Default etc). Without this, the new
  # home.file entries would conflict with stale symlinks. Idempotent.
  home.activation.braveGpuCleanup =
    lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      gpuDir="$HOME/.config/BraveSoftware/Brave-Browser-GPU"
      for sub in "Default" "External Extensions" "policies" "Local State"; do
        link="$gpuDir/$sub"
        if [ -L "$link" ]; then
          # Stale symlink from old design — remove so home.file (or Brave
          # itself, for Default/) can manage the path freely.
          rm "$link"
        fi
      done
    '';
}
