# Home-manager runtime mechanics — caches computed once per switch, and the
# post-linkGeneration pass that makes deployed dotfiles writable.
{ config, lib, pkgs, ... }:

{
  # Greeting caches — CLI versions + store-path count computed ONCE
  # per switch. fish_greeting used to spawn claude/goose/ant (up to
  # 9s of timeout-blocking) and readdir all of /nix/store on EVERY
  # new shell (2026-08-08 audit); now it just cats these files.
  home.activation.greetingVersionCache = lib.hm.dag.entryAfter ["installPackages"] ''
    ${pkgs.bash}/bin/bash ${../scripts/greeting-version-cache.sh} || true
  '';

  # ── Writable dotfiles (see ba_flakes_desktop/common.nix for rationale) ──
  # Swap each store-backed HM symlink for a writable copy right after
  # linkGeneration so deployed files are editable for imperative tests;
  # the next switch re-links then re-copies (declarative always wins).
  # Data-driven from config.home.file (xdg.configFile feeds into it).
  home.activation.unfreezeHmFiles =
    let
      _writableTargets = pkgs.writeText "hm-writable-targets"
        (lib.concatMapStringsSep "\n" (f: f.target) (lib.attrValues config.home.file));
    in lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      TARGETS_FILE=${_writableTargets} \
      PATH="${pkgs.coreutils}/bin:$PATH" \
      ${pkgs.bash}/bin/bash ${../scripts/hm-unfreeze-files.sh} || true
    '';
}
