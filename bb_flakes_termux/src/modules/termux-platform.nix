# Termux/Android platform glue — the bits that exist only because this is
# nix-on-droid inside a proot, plus the $HOME scaffolding that depends on them.
{ config, lib, pkgs, jbMonoNerd, ... }:

{
  # This runs BEFORE packages are linked
  home.activation.createUsrLib = lib.hm.dag.entryBefore ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p /data/data/com.termux.nix/files/usr/lib
    $DRY_RUN_CMD chmod 755 /data/data/com.termux.nix/files/usr/lib
  '';

  # DNS self-heal — environment.etc points /etc/resolv.conf at
  # /etc/static/resolv.conf (a store path). If that store-etc lacks
  # resolv.conf (an older generation, or a partial activation) the
  # symlink DANGLES → the system resolver reads nothing → DNS dies →
  # and you then CANNOT `nix-on-droid switch` to fix it because
  # fetching needs DNS. Deadlock. `test -s` follows the symlink and is
  # false when it dangles or is empty; only then do we drop the dead
  # link and write a REAL resolver file (matches the declared servers,
  # cannot dangle). No-op on a healthy system.
  home.activation.resolvConfSelfHeal = lib.hm.dag.entryAfter ["linkGeneration"] ''
    if [ ! -s /etc/resolv.conf ]; then
      $DRY_RUN_CMD rm -f /etc/resolv.conf 2>/dev/null || true
      $DRY_RUN_CMD sh -c 'printf "nameserver 10.0.0.1\nnameserver 1.1.1.1\n" > /etc/resolv.conf' 2>/dev/null || true
      $DRY_RUN_CMD chmod 644 /etc/resolv.conf 2>/dev/null || true
    fi
  '';

  # Create Unison target folder on Android storage
  home.activation.createUnisonTarget = lib.hm.dag.entryBefore ["writeBoundary"] ''
    $DRY_RUN_CMD mkdir -p "/storage/emulated/0/Mounts/Termux-Home"
  '';

  home.activation.xdgRuntimeDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.cache/xdg-runtime"
    chmod 700 "$HOME/.cache/xdg-runtime"
  '';

  # Initialize $HOME as minimal git repo so Claude Code uses git ls-files (instant)
  # instead of ripgrep fallback (97s timeout scanning all of $HOME)
  home.activation.initHomeGit = lib.hm.dag.entryAfter ["linkGeneration"] ''
    if [ ! -d "$HOME/.git" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git init "$HOME" 2>/dev/null
    fi
    # Ensure .gitignore is tracked (it's a nix-managed symlink)
    $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$HOME" add -f .gitignore 2>/dev/null || true
  '';

  # Symlink nix-profile bins into Termux usr/bin so non-shell processes
  # (Claude Code, Android app launchers) can find nix-installed tools
  # without relying on shell init PATH expansion.
  home.activation.linkNixBinsToTermux = lib.hm.dag.entryAfter ["installPackages"] ''
    ${pkgs.bash}/bin/bash ${../scripts/link-nix-bins-termux.sh} || true
  '';

  # Termux font — JetBrainsMono Nerd Font
  home.file.".termux/font.ttf".source =
    "${jbMonoNerd}/share/fonts/truetype/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf";

  # Minimal .gitignore so $HOME is a git repo (ignore everything)
  # This makes Claude Code use `git ls-files` (instant) instead of ripgrep (97s timeout)
  home.file.".gitignore".text = "*";

  # Unison profile for bidirectional sync
  home.file.".unison/termux-home.prf".text = ''
    # Bidirectional sync: Termux home <-> Android storage
    root = /data/data/com.termux.nix/files/home
    root = /storage/emulated/0/Mounts/Termux-Home

    # Android storage compatibility
    perms = 0
    dontchmod = true
    links = false

    # Prefer newer files on conflict
    prefer = newer

    # Auto-accept non-conflicting changes
    auto = true
    batch = true

    # Only sync specific folders (avoid system files)
    path = nix-home-manager
    path = desktop
  '';
}
