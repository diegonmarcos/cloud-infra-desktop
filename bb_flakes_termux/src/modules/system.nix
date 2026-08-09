# System-level (nix-on-droid) configuration: identity, resolver, nix daemon
# options, and the global session environment.
{ config, lib, pkgs, dtkNode, ... }:

{
  system.stateVersion = "24.05";
  environment.etcBackupExtension = ".bak";

  # proot resolver must match the vault termux WireGuard profile DNS
  # (10.0.0.1 Hickory wg0, 1.1.1.1 fallback — see
  # vault/A0_keys/providers/wireguard/termux{,-public}/config).
  # nix-on-droid's default resolv.conf is 1.1.1.1/8.8.8.8
  # — that bypasses Hickory, so *.diegonmarcos.com resolves to the
  # PUBLIC edge instead of the wg IP and WG-only services (MCP, etc.)
  # 403. Hickory-first = wg-IP resolution.
  # NOTE: 10.1.0.1 removed 2026-07-02 — NO DNS service exists on the
  # wg-public hub (oci-analytics has no :53 listener and none is
  # declared); a dead resolver in the list only adds per-lookup
  # timeouts (broke mail-client resolution on Android).
  environment.etc."resolv.conf".text = lib.mkForce ''
    nameserver 10.0.0.1
    nameserver 1.1.1.1
  '';

  nix.extraOptions = ''
    experimental-features = nix-command flakes
    # Phone has 7GB RAM. max-jobs=2 × cores=4 = up to 8 parallel
    # compile jobs which OOM-thrashed during openssh-pinned + ncurses
    # static builds (ate 4.6GB swap). Cap at 1 job × 2 cores so big
    # native compiles finish without swap death.
    max-jobs = 1
    cores = 2
    auto-optimise-store = false
    min-free = 1073741824
    min-free-check-interval = 30
    keep-derivations = false
  '';

  time.timeZone = "Europe/Athens";

  # Global PATH and SHELL for Bash/Zsh/Fish
  environment.sessionVariables = {
    SHELL = "${pkgs.bash}/bin/bash";
    PATH = "$HOME/.node_modules/node_modules/.bin:$HOME/.local/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH";
    NODE_PATH = "$HOME/.node_modules/node_modules";
    # DTK webhooks node identity (Android can't sethostname; see flake.nix `dtkNode`)
    DTK_NODE_NAME = dtkNode;
    # Global memory allocator fix for Android - propagates to ALL child processes
    LD_PRELOAD = "${pkgs.mimalloc}/lib/libmimalloc.so";
    MIMALLOC_PAGE_RESET = "0";
    MIMALLOC_LARGE_OS_PAGES = "0";
    MALLOC_ARENA_MAX = "2";
    # Terraform: shared plugin cache (avoid 100MB+ provider binaries per project)
    TF_PLUGIN_CACHE_DIR = "$HOME/.terraform.d/plugin-cache";
    # fish/others expect a private runtime dir; unset → "Runtime path
    # not available". Created 0700 by the home.activation below.
    XDG_RUNTIME_DIR = "$HOME/.cache/xdg-runtime";
    # Locale — en_DK.UTF-8 = ISO-8601 dates + 24h.
    #
    # LC_ALL REMOVED (2026-08-09). The old comment here claimed
    # LOCALE_ARCHIVE would "already be in scope" — the opposite is
    # true: nix renders an attrset in SORTED key order, and
    # LANG < LC_ALL < LD_PRELOAD < LOCALE_ARCHIVE, so LC_ALL was
    # exported BEFORE the archive it needs. bash then failed its
    # setlocale and printed
    #   "warning: setlocale: LC_ALL: cannot change locale (en_DK.UTF-8)"
    # on every single login. Ordering inside sessionVariables is not
    # controllable, so the fix is to stop setting the variable that
    # trips it: LANG alone already supplies the default for every LC_*
    # category, LC_ALL is the override hammer on top (and only LC_ALL
    # was ever named in the warning).
    LANG = "en_DK.UTF-8";
    LOCALE_ARCHIVE = "${pkgs.glibcLocales}/lib/locale/locale-archive";
  };

  user.shell = "${pkgs.fish}/bin/fish";
  # This closure is built in CI, where nix-on-droid would bake
  # /etc/passwd from the RUNNER's `id -u` (1000). Pin the phone's real
  # Android app uid so getpwuid(10635) resolves → whoami + sshd client
  # (git push over SSH) work. Update if the app is reinstalled with a
  # different uid (`id -u`).
  user.uid = 10635;
  # Same CI-vs-phone mismatch for the group: the runner's `id -g` (100)
  # gets baked as pw_gid, but the Android /dev/pts nodes are owned by
  # gid 10635 and we're NOT in group 100. sshd's pty_setowner then does
  # chown(pts, 10635, 100) as non-root → EPERM → fatal → the app's
  # terminal session dies right after auth ("Auth OK but no terminal").
  # Pinning gid=10635 makes pw_gid match the pts group → no chown needed.
  user.gid = 10635;
}
