# Home-manager runtime mechanics — caches computed once per switch, and the
# post-linkGeneration pass that makes deployed dotfiles writable.
{ config, lib, pkgs, ... }:

let
  # ONE list, read by BOTH passes below. If refreeze ever saw a different set of
  # paths than unfreeze wrote, it would leave behind exactly the conflicts it
  # exists to remove, so the two deliberately share this derivation.
  _writableTargets = pkgs.writeText "hm-writable-targets"
    (lib.concatMapStringsSep "\n" (f: f.target) (lib.attrValues config.home.file));
in
{
  # Greeting caches — CLI versions + store-path count computed ONCE
  # per switch. fish_greeting used to spawn claude/goose/ant (up to
  # 9s of timeout-blocking) and readdir all of /nix/store on EVERY
  # new shell (2026-08-08 audit); now it just cats these files.
  home.activation.greetingVersionCache = lib.hm.dag.entryAfter ["installPackages"] ''
    ${pkgs.bash}/bin/bash ${../scripts/greeting-version-cache.sh} || true
  '';

  # ── Refreeze: the missing FIRST half of the writable-dotfiles design ──
  # unfreezeHmFiles (below) leaves a regular file where every managed symlink
  # belongs, so the NEXT switch finds one "existing file in the way" per managed
  # path. build.sh answers that with a timestamped HOME_MANAGER_BACKUP_EXT so the
  # switch cannot abort — which turned the conflict into a full set of
  # <file>.hm-bak-<timestamp> minted on EVERY switch, forever (8 in $HOME alone,
  # plus whatever sits under .claude/ and .config/). Deleting the copies we can
  # PROVE are ours, before linkGeneration looks, means there is no conflict left
  # to back up. A dotfile the owner actually hand-edited differs from the store
  # copy, survives this pass, and is backed up exactly as before — that backup is
  # a real conflict and is the only thing the extension was ever for.
  home.activation.refreezeHmFiles =
    lib.hm.dag.entryBefore [ "linkGeneration" ] ''
      TARGETS_FILE=${_writableTargets} \
      PATH="${pkgs.coreutils}/bin:${pkgs.diffutils}/bin:$PATH" \
      ${pkgs.bash}/bin/bash ${../scripts/hm-refreeze-files.sh} || true
    '';

  # ── Writable dotfiles (see ba_flakes_desktop/common.nix for rationale) ──
  # Swap each store-backed HM symlink for a writable copy right after
  # linkGeneration so deployed files are editable for imperative tests;
  # the next switch re-links then re-copies (declarative always wins).
  # Data-driven from config.home.file (xdg.configFile feeds into it).
  home.activation.unfreezeHmFiles =
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      TARGETS_FILE=${_writableTargets} \
      PATH="${pkgs.coreutils}/bin:$PATH" \
      ${pkgs.bash}/bin/bash ${../scripts/hm-unfreeze-files.sh} || true
    '';
}
