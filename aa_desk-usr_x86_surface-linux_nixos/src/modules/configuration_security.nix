# Users, PAM, keyring, sudo, logind, udev rules
{ config, pkgs, lib, ... }:

let
  # Lid-close behaviour is shared with PowerDevil/UPower via a single SoT.
  # See cloud-data-power.json (events.lid_close).
  pwrJson = builtins.fromJSON (builtins.readFile ./cloud-data-power.json);
  banned  = pwrJson.actions.never;
  guard   = name: v:
    if builtins.elem v banned
    then throw "configuration_security: ${name}=${v} is in actions.never (Surface S3 is broken)"
    else v;
  lid     = pwrJson.events.lid_close;
in

{
  # ═══════════════════════════════════════════════════════════════════════════
  # USER ACCOUNTS (Fixed UIDs for cross-OS compatibility)
  # ═══════════════════════════════════════════════════════════════════════════

  users.mutableUsers = false;  # Users defined only in config, not /etc/passwd

  users.users.diego = {
    isNormalUser = true;
    description = "Diego";
    uid = 1000;
    group = "users";
    # Password: 1234567890 (hashedPassword ensures it works every boot, not just first)
    hashedPassword = "$6$0lk5nosoLlNAcDTp$or4FVVs/Lq1gFMYgjuw6FUdh6dKNE8e/vBClzgik290mxMCzctvN43odeGq7D.qpuJCyyDxJJAsSQNSsB3Vst0";
    extraGroups = [
      "wheel" "networkmanager" "video" "audio"
      "docker" "podman" "kvm" "libvirtd"
      "render"  # GPU DRM render node access (Wayland zero-copy + Brave/Chromium GPU compositing)
    ];
    shell = pkgs.fish;
    # Home is a dedicated btrfs subvolume - fully persistent
    home = "/home/diego";
    # Authorized SSH keys (2026-06-15): required now that sshd is key-only
    # (configuration_network.nix PasswordAuthentication=false). These are
    # diego's own public keys; the S21/termux phone uses the SAME keypair
    # (vault A0_keys/providers/ssh-s21 — identical bodies), so this also
    # authorizes phone→desktop over wg0. Pubkeys are public — safe to commit.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHv4vbpBAxwo4C6pLR1r4qbfxDFc2GlOZn2DFNQA7HM diego@diego-surfacepro8"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+R13feNM+RTKKxi4eUIHOxAdbQiG23G1OyGWEZtk6K43+/D9nq6ddkC0MapckgekPFChqu1rw/voiD/+A+U85iqTZlb3FYv6uDGkADY2t/qsRXmpJ3hBXcEoXLhqvzpsZ44nuTHCpfjsNdPLATnZx5SnVqx5I67WMSszCwJaqaYW/zpuZxx1yM3iIgtyIHVWk4DHGSkXa/kXmOgN3dVQxSMEIMVUJiQJ5vl1SmQHsAq/8M6O6X0YSVE/nZjxMUhGxf1mv9I5iw/u4PYP1/T23i/VthIVSlciRp0lX80abNblRoIkvvXLeMm7gA8h3T00L5ehTMpGdEVlfHa1gQrhlgjXjQS6pOR6U9BAidBD94sRYLUJ44R3bfX0m6QVvuqPLu6N/TmsDdXNLuMlJ90sUkopR/FWd0aC01/nAKu8CdKd0Vgusibl/NTjMFOx1My3Pw+ma5SZPC6is+n53F+vkGlwFM1+gEdNJjxPBcbkUgM27IlGc+lUiWtKCVJ9VJYM= diego@diego-surfacepro8"
    ];
  };

  users.users.guest = {
    isNormalUser = true;
    description = "Guest User";
    uid = 1001;
    group = "users";
    # Password: 1234567890 (same as diego for convenience)
    hashedPassword = "$6$0lk5nosoLlNAcDTp$or4FVVs/Lq1gFMYgjuw6FUdh6dKNE8e/vBClzgik290mxMCzctvN43odeGq7D.qpuJCyyDxJJAsSQNSsB3Vst0";
    extraGroups = [ "networkmanager" "video" "audio" "render" ];
    shell = pkgs.fish;
    home = "/home/guest";
  };

  # Fixed GIDs for groups (mkForce to override module defaults)
  users.groups.users.gid = 100;
  users.groups.docker.gid = lib.mkForce 998;
  users.groups.podman.gid = lib.mkForce 997;
  users.groups.libvirtd.gid = lib.mkForce 996;
  users.groups.kvm.gid = lib.mkForce 995;

  security.sudo.wheelNeedsPassword = false;

  # Root password (same as diego: 1234567890)
  users.users.root.hashedPassword = "$6$0lk5nosoLlNAcDTp$or4FVVs/Lq1gFMYgjuw6FUdh6dKNE8e/vBClzgik290mxMCzctvN43odeGq7D.qpuJCyyDxJJAsSQNSsB3Vst0";

  # ═══════════════════════════════════════════════════════════════════════════
  # PER-USER BLUETOOTH (PAM session hook)
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # On login: symlink /var/lib/bluetooth -> ~/.local/share/bluetooth
  # On logout: remove symlink
  # This makes bluetooth pairings portable with the user's home

  # NOTE: Bluetooth portable pairings disabled for now
  # The .text = lib.mkAfter approach REPLACES the entire PAM config instead of appending,
  # which breaks authentication. This needs a different approach (udev rules or systemd service).
  # TODO: Implement bluetooth symlink via systemd user service instead of PAM

  # ═══════════════════════════════════════════════════════════════════════════
  # KEYRING SERVICES (For WiFi passwords)
  # ═══════════════════════════════════════════════════════════════════════════

  services.gnome.gnome-keyring.enable = true;
  security.pam.services.sddm.enableGnomeKeyring = true;
  security.pam.services.login.enableGnomeKeyring = true;

  # KWallet for KDE sessions
  security.pam.services.sddm.enableKwallet = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # LOGIND - Lid/Power Button Behavior
  # ═══════════════════════════════════════════════════════════════════════════
  # Lid-close behaviour read from cloud-data-power.json (events.lid_close).
  # Surface Pro 8 suspend/resume is unreliable: surface_hid reprobe fails
  # (error -71), DRM atomic commits error, and logind marks the session
  # Active=no, which causes kscreenlocker to silently reject correct passwords.
  # The `actions.never` guard in cloud-data-power.json prevents anyone setting
  # a banned verb (sleep/suspend/s2idle).
  services.logind.lidSwitch              = guard "lidSwitch"              lid.battery;
  services.logind.lidSwitchExternalPower = guard "lidSwitchExternalPower" lid.ac;
  services.logind.lidSwitchDocked        = guard "lidSwitchDocked"        lid.docked;

  # ═══════════════════════════════════════════════════════════════════════════
  # UDEV RULES (Device naming for Dolphin/KDE)
  # ═══════════════════════════════════════════════════════════════════════════

  services.udev.extraRules = ''
    # Set friendly name for btrfs pool in Dolphin/KDE file manager
    # This overrides the default which shows just "home-diego"
    ENV{ID_FS_TYPE}=="btrfs", ENV{ID_FS_LABEL}=="pool", ENV{UDISKS_NAME}="NixOS Pool (btrfs)"

    # Prevent SAM (Surface Aggregator Module) autosuspend - fixes Type Cover disconnects
    # Without this, power management suspends SAM communication, causing trackpad/keyboard failures
    ACTION=="add", SUBSYSTEM=="platform", ATTR{driver}=="surface_aggregator", ATTR{power/control}="on"

    # Prevent Type Cover devices from suspending (trackpad/keyboard on SAM bus)
    # The above rule only affects the main controller; this targets the child devices (01:15:*)
    ACTION=="add", SUBSYSTEM=="surface_aggregator", ATTR{power/control}="on"

    # Suppress ghost Type Cover device 01:15:02:02:00 - always fails probe with error -71
    # SAM firmware 11.401.139 advertises this device but returns empty HID descriptor (0 bytes).
    # Preventing surface_hid from probing it avoids SAM bus contention that can freeze the touchpad.
    ACTION=="add", SUBSYSTEM=="surface_aggregator", ATTR{modalias}=="ssam:d01c15t02i02f00", ATTR{driver_override}="none"
  '';
}
