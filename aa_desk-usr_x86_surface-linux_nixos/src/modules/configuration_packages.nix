# System packages, shells, flatpak
{ config, pkgs, lib, pkgsUnstable, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # NIX-LD: run generic dynamically-linked Linux binaries
  # ═══════════════════════════════════════════════════════════════════════════
  # Self-updating third-party tools (Claude Code native installer in
  # ~/.local/share/claude/versions/, similar vendored ELF binaries) link
  # against glibc and expect /lib64/ld-linux-x86-64.so.2. Without nix-ld that
  # path is NixOS's stub-ld → "Could not start dynamically linked executable".
  # nix-ld installs a real loader shim there instead.
  # Incident 2026-06-11: claude auto-update to 2.1.172 replaced a previously
  # interpreter-patched binary and locked the CLI out until re-patched.
  # With nix-ld enabled, future auto-updates run unpatched.
  # If a tool reports a missing .so, add it to programs.nix-ld.libraries.
  programs.nix-ld.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # SYSTEM PACKAGES - MINIMAL
  # ═══════════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # ─── Waydroid launcher ─────────────────────────────────────────────────
    # MOVED 2026-06-25 to configuration_waydroid-launcher.nix — the bulletproof
    # `waydroid-launch` (Wayland-env discovery, stale-state reset, boot watchdog
    # + recycle, NOPASSWD root ops, desktop entry). Data-driven: waydroid.json.

    # ─── Absolute Minimum CLI (system-level only) ───────────────────────────
    # vim, git, curl, wget, nodejs → managed by home-manager profiles
    fish  # Must be here for users.users.*.shell = pkgs.fish

    # ─── System tools (required for maintenance / boot) ─────────────────────
    btrfs-progs
    cryptsetup
    # aa_bootloader (../aa_bootloader/) is the SoT for boot; its build.sh
    # needs these tools at deploy time. Without them, the engine falls back
    # to scanning /nix/store, which is fragile.
    efibootmgr   # NVRAM management (apply.sh + install-refind.sh)
    grub2_efi    # grub-mkimage + modules dir for render-grub-binaries.sh

    # ─── Openbox session essentials (launched by SDDM, must be system-level) ─
    openbox obconf
    polybar nitrogen feh rofi dunst picom xterm

    # ─── Wayland kiosk ──────────────────────────────────────────────────────
    cage wlr-randr

    # ─── SDDM Astronaut Theme (Qt6) - custom glassmorphism ───────────────────
    sddm-astronaut-custom

    # ─── Virtual Keyboard (Surface Pro touchscreen) ───────────────────────────
    # Must be system-level: used at SDDM login screen (pre-user-session)
    # NOTE: maliit-keyboard REMOVED — causes trackpad click freeze on Plasma 6 Wayland
    #   see: https://github.com/maliit/keyboard/issues/210
    # maliit-keyboard
    # maliit-framework
    onboard              # Full-featured: arrows, Fn keys, mouse buttons, word prediction
    kdePackages.qtvirtualkeyboard  # Qt virtual keyboard for SDDM login screen

    # ─── Camera (KDE-native) ──────────────────────────────────────────────────
    # Kamoso — KDE's webcam app (2026-06-15, requested). From pkgsUnstable:
    # kdePackages.kamoso is meta.broken=true in nixpkgs 24.11 (build fails),
    # broken=false in unstable. Same pkgsUnstable escape hatch as the fido2
    # broker; a standalone app carries its own Qt closure so it won't clash
    # with Plasma 6.2.5's Qt. CAVEAT: Kamoso is GStreamer-based, not libcamera,
    # so on this IPU6 hardware it may not enumerate the cameras (GNOME Snapshot
    # works because it's libcamera-native). Added as requested.
    pkgsUnstable.kdePackages.kamoso

    # ─── Wallpapers ───────────────────────────────────────────────────────────
    kdePackages.plasma-workspace-wallpapers

    # ─── KDE system-level integrations ────────────────────────────────────────
    # kdeconnect needs system D-Bus + firewall rules via programs.kdeconnect
    kdePackages.kdeconnect-kde

    # All other KDE apps → managed by home-manager profile 7 (productivity)
    #                      and profile 8 (media-graphics)
  ];

  # ═══════════════════════════════════════════════════════════════════════════
  # SHELLS
  # ═══════════════════════════════════════════════════════════════════════════

  programs.fish.enable = true;
  programs.zsh.enable = true;
  programs.bash.completion.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # FLATPAK (For user apps)
  # ═══════════════════════════════════════════════════════════════════════════

  services.flatpak.enable = true;
  # nix-ld exports NIX_LD/NIX_LD_LIBRARY_PATH globally (see above) so arbitrary
  # dynamically-linked binaries can find a loader. systemd imports that into
  # every user-session process, including flatpak's own CLI/portal helpers —
  # so flatpak's dynamic linker resolves libs through nix-ld's (older,
  # nixos-24.11-pinned) glibc/glib instead of its own bundled runtime,
  # producing version mismatches like "GLIBC_ABI_DT_X86_64_PLT not found".
  # Unset those vars for flatpak specifically; it must never see nix-ld's libs.
  services.flatpak.package = pkgs.symlinkJoin {
    name = "flatpak-no-nix-ld";
    paths = [ pkgs.flatpak ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/flatpak \
        --unset NIX_LD --unset NIX_LD_LIBRARY_PATH --unset LD_LIBRARY_PATH
    '';
  };

  # Add Flathub remote on boot (only if not already configured)
  # Uses ConditionPathExists to skip entirely if flathub is already set up
  systemd.services.flatpak-add-flathub = {
    description = "Add Flathub remote to Flatpak";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nss-lookup.target" ];
    wants = [ "network-online.target" "nss-lookup.target" ];
    unitConfig = {
      # Skip if flathub remote already exists (persisted in /var/lib/flatpak)
      ConditionPathExists = "!/var/lib/flatpak/repo/flathub.trustedkeys.gpg";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Retry up to 3 times with 10s delay between attempts
      Restart = "on-failure";
      RestartSec = "10s";
      RestartMaxDelaySec = "30s";
      StartLimitIntervalSec = "120";
      StartLimitBurst = "3";
      ExecStart = pkgs.writeShellScript "flatpak-add-flathub" ''
        # Wait for DNS to be available
        for i in 1 2 3 4 5; do
          if ${pkgs.iputils}/bin/ping -c1 -W2 flathub.org >/dev/null 2>&1; then
            break
          fi
          echo "[FLATPAK] Waiting for network... (attempt $i/5)"
          sleep 2
        done

        echo "[FLATPAK] Adding Flathub remote..."
        if ${pkgs.flatpak}/bin/flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
          echo "[FLATPAK] SUCCESS: Flathub remote added"
        else
          echo "[FLATPAK] ERROR: Failed to add Flathub (exit $?)" >&2
          echo "[FLATPAK] HINT: Run manually: flatpak remote-add flathub https://flathub.org/repo/flathub.flatpakrepo" >&2
          exit 1
        fi
      '';
    };
  };
}
