# my-konsole on a raw virtual console: Alacritty (Rust/GPU terminal) hosted by
# cage (Wayland kiosk compositor) on a dedicated VT, since Alacritty has no
# DRM/KMS backend of its own. Runs alongside the normal getty VTs (tty1-6) and
# the SDDM/Plasma session — does not replace either.

{ config, pkgs, lib, ... }:

{
  environment.systemPackages = [ pkgs.alacritty pkgs.cage ];

  # ponytail: one fixed VT (tty8); parametrize per-VT only if ever needed.
  systemd.services."my-konsole@tty8" = {
    description = "my-konsole (Alacritty under cage) on tty8";
    conflicts = [ "getty@tty8.service" ];
    after = [ "getty@tty8.service" "systemd-user-sessions.service" ];
    unitConfig.ConditionPathExists = "/dev/tty8";
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.cage}/bin/cage -s -- ${pkgs.alacritty}/bin/alacritty";
      User = "diego";
      PAMName = "login";
      TTYPath = "/dev/tty8";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
      StandardInput = "tty";
      StandardOutput = "journal";
      StandardError = "journal";
      Restart = "on-failure";
      UtmpIdentifier = "tty8";
      UtmpMode = "user";
    };
  };
}
