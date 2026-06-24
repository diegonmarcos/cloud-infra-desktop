# productivity/kde-tools.nix — KDE Plasma 6 application bundle + dialog helpers
# Use kdePackages.* (KDE 6) consistently to avoid mixing Qt5/Qt6 derivations.
{ config, pkgs, lib, ... }:
{
  home.packages = with pkgs; [
    kdePackages.dolphin          # Use KDE 6 version to match system konsole
    kdePackages.dolphin-plugins  # Git/SVN integration
    kdePackages.ark              # Archive manager (GUI)
    kdePackages.kate             # Advanced text editor
    kdePackages.kcalc            # Calculator
    kdePackages.spectacle        # Screenshot tool
    kdePackages.kmousetool       # Accessibility - auto-click
    kdePackages.partitionmanager # Disk partition manager
    kdePackages.filelight        # Disk usage visualizer
    kdePackages.kcharselect      # Character selector
    kdePackages.ksystemlog       # System log viewer
    kdePackages.kfind            # File search
    kdePackages.krdc             # Remote desktop client
    kdePackages.krfb             # Remote desktop server (VNC)
    kdePackages.skanlite         # Scanner app
    zenity                       # GTK dialog helper (used by scripts)
    kdePackages.kdialog          # KDE dialog helper (used by scripts); 25.05: top-level alias removed
  ];
}
