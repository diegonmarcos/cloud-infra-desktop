# security-net/passwords-gui.nix — password manager GUI + CLI
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    bitwarden-desktop  # Vaultwarden/Bitwarden GUI client
    rbw               # Rust Bitwarden CLI — backend for da_autofill-rbw-rofi
    pinentry-qt       # GPG pinentry for rbw master-password unlock
    rofi              # picker (X11 + Wayland) for da_autofill-rbw-rofi
    wofi              # picker (Wayland-native) for da_autofill-rbw-rofi
    wtype             # Wayland keystroke synth for da_autofill-rbw-rofi
    xdotool           # X11 keystroke synth for da_autofill-rbw-rofi
    wl-clipboard      # `wl-copy` for TOTP→clipboard path
    xclip             # X11 clipboard fallback
    libnotify         # `notify-send` for autofill error notifications
  ];
}
