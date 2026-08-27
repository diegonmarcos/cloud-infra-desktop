# Rescue specialisation — native-install — clean module set + full dev env
#
# Goal
# ────
# Behave like a "fresh NixOS install" with NO custom modules disabled by
# mkForce — strong insulation against bugs in *our* custom modules
# (battery-watchdog, system-protection slices, observability, container
# hardening, hibernate hooks, …). All persistent btrfs subvolumes stay
# mounted so user data, /home, /nix and /mnt/shared are reachable for
# recovery work. Includes the dev tooling needed to actually fix the
# broken main config: gcc/make/git, vim/neovim, tmux, ripgrep/fd/bat,
# btrfs/luks/parted, smartctl/iotop/strace, nodejs+npm so claude-code
# can be run via `npx @anthropic-ai/claude-code`.
#
# Caveats
# ───────
# 1. Specialisation in same flake → still shares the parent's kernel,
#    initrd, nixpkgs input. To insulate against nixpkgs regressions
#    too, future work: add a pinned nixpkgs flake input and route this
#    specialisation through it (Variant B).
# 2. mkForce disables EVERYTHING graphical and our heavy custom services
#    so the rescue boots fast on a healthy or a degraded kernel.
# 3. Persistent mounts are inherited from the parent's fileSystems.<x>
#    declarations — we don't redefine them here; we just don't disable
#    them.
{ config, pkgs, lib, ... }:

{
  specialisation.rescue-native-install.configuration = {

    # ─────────────────────────────────────────────────────────────────
    # Hibernate-image invalidation + swap policy
    # ─────────────────────────────────────────────────────────────────
    # Invalidate any pending hibernate image (safe swapfile-header rewrite,
    # gated on noresume) so the next default boot can't resume stale RAM
    # state on top of whatever this rescue session modified.
    # boot.json: swap_hibernate.hibernate_invalidation.trigger_specialisations
    imports = [ ./configuration_rescue_invalidate_hibernate.nix ];

    # boot.json: kernel.specialisations.rescue-native-install.swap_disabled.
    # No disk swap in rescue — the swapfile stays untouched except for the
    # explicit invalidation above. (zram swap is unaffected.)
    swapDevices = lib.mkForce [ ];

    # ─────────────────────────────────────────────────────────────────
    # Shell + login
    # ─────────────────────────────────────────────────────────────────
    # Force bash for root (NEVER fish/zsh in rescue — they may be the
    # broken thing). Auto-login on tty1 so the user reaches a shell
    # even if PAM/login chain is half-broken.
    users.users.root.shell             = lib.mkForce pkgs.bashInteractive;
    services.getty.autologinUser       = lib.mkForce "root";

    # ─────────────────────────────────────────────────────────────────
    # Disable EVERYTHING graphical
    # ─────────────────────────────────────────────────────────────────
    services.displayManager.sddm.enable           = lib.mkForce false;
    services.xserver.enable                       = lib.mkForce false;
    services.desktopManager.plasma6.enable        = lib.mkForce false;
    services.xserver.desktopManager.gnome.enable  = lib.mkForce false;
    systemd.services.display-manager.enable       = lib.mkForce false;
    systemd.services.display-manager.wantedBy     = lib.mkForce [ ];
    boot.plymouth.enable                          = lib.mkForce false;

    # ─────────────────────────────────────────────────────────────────
    # Disable our heavy custom protection / observability services
    # so the rescue isn't dragged down by anything we built.
    # mkIf-on-disable: the service is only created when its module's
    # `enable` toggle (or our convention) is true; lib.mkForce false
    # is the universal off switch.
    # ─────────────────────────────────────────────────────────────────
    systemd.services.battery-watchdog.enable       = lib.mkForce false;
    systemd.timers.battery-watchdog.enable         = lib.mkForce false;

    # ─────────────────────────────────────────────────────────────────
    # Sleep / hibernate handling
    # ─────────────────────────────────────────────────────────────────
    # Strip resume= and resume_offset= and add noresume so rescue ALWAYS
    # does a fresh boot, never an interrupted-hibernate resume that could
    # re-enter a hibernate loop. Same as rescue-current-gen. `noresume` is
    # also the ConditionKernelCommandLine gate for
    # rescue-invalidate-hibernate.service (it can never fire on a
    # resume-capable boot).
    boot.kernelParams = lib.mkForce [
      "noresume"
      "mem_sleep_default=deep"
      "psi=1"
      "loglevel=4"
      "audit=1"
    ];
    boot.resumeDevice = lib.mkForce "";

    # ─────────────────────────────────────────────────────────────────
    # Network — keep NetworkManager so nmtui + WiFi work in the
    # text console. We do NOT keep firewall hardening etc.
    # ─────────────────────────────────────────────────────────────────
    networking.networkmanager.enable = lib.mkForce true;

    # ─────────────────────────────────────────────────────────────────
    # Dev environment — what makes this a "native-install" rescue:
    # full toolchain, editors, search/file utilities, disk recovery,
    # nodejs for `npx claude-code`. Adds to (does not replace) any
    # parent systemPackages — but the parent's heavy stuff is already
    # disabled above so this stays light at runtime.
    # ─────────────────────────────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      # Toolchain
      gcc
      gnumake
      pkg-config
      git
      git-lfs

      # Editors
      vim
      neovim
      nano

      # Shell ergonomics + search/file tools
      tmux
      htop
      btop
      ripgrep
      fd
      bat
      tree
      file
      jq
      yq

      # System / process inspection
      lsof
      strace
      iotop
      pciutils
      usbutils
      smartmontools
      dmidecode

      # Filesystem / disk tools
      btrfs-progs
      e2fsprogs
      dosfstools
      ntfs3g
      cryptsetup
      gptfdisk
      parted
      lvm2
      testdisk
      ddrescue
      rsync

      # Networking
      networkmanager  # nmtui/nmcli
      iw
      wirelesstools
      wpa_supplicant
      inetutils       # ping, hostname
      curl
      wget
      mtr

      # Nix tooling
      nix-tree
      nix-diff

      # Claude Code via npx — keep node + npm available so the user
      # can run `npx @anthropic-ai/claude-code` (no global install).
      nodejs_20
      nodePackages.npm
    ];

    # ─────────────────────────────────────────────────────────────────
    # Banner — tells the user exactly which rescue tier they're in
    # and what's available.
    # ─────────────────────────────────────────────────────────────────
    environment.etc."motd".text = ''

      ╔═══════════════════════════════════════════════════════════════════╗
      ║              NIXOS RESCUE — native-install                        ║
      ╠═══════════════════════════════════════════════════════════════════╣
      ║                                                                   ║
      ║   Clean module set: NO custom watchdog / protection / observ.     ║
      ║   All persistent btrfs subvolumes still mounted (inherited):      ║
      ║       /nix  /home/diego  /home/guest  /mnt/shared  /tmp           ║
      ║                                                                   ║
      ║   WiFi:        nmtui  or  nmcli device wifi connect SSID pass PW  ║
      ║   Editors:     vim  nvim  nano                                    ║
      ║   Search:      rg, fd, bat, jq, yq                                ║
      ║   Build:       gcc make git                                       ║
      ║   Disks:       lsblk, btrfs fi show, cryptsetup status pool       ║
      ║   Recovery:    testdisk, ddrescue, rsync                          ║
      ║                                                                   ║
      ║   Claude:      npx @anthropic-ai/claude-code                      ║
      ║   Node REPL:   node                                               ║
      ║                                                                   ║
      ║   Rebuild:     nixos-rebuild switch \                             ║
      ║                  --flake /home/diego/git/cloud-infra-desktop/\                   ║
      ║                  aa_desk-usr_x86_surface-linux_nixos/src#surface  ║
      ║   Rollback:    nixos-rebuild --rollback switch                    ║
      ║   Generation:  nix-env -p /nix/var/nix/profiles/system --list-... ║
      ║                                                                   ║
      ║   Logs:        journalctl -xb       Exit:   reboot                ║
      ║                                                                   ║
      ╚═══════════════════════════════════════════════════════════════════╝

    '';
  };
}
