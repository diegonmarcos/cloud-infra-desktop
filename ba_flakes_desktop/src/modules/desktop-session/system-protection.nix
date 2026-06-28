# System Protection — Desktop (Surface Pro 8)
#
# System-level cgroup slices, sysctl, earlyoom, dropbear rescue, swap, and
# disk-watchdog are owned ENTIRELY by the NixOS host flake (declarative):
#   aa_desk-usr_x86_surface-linux_nixos/src/modules/configuration_system-protection*.nix
#
# Home-manager keeps only what is genuinely user-level:
#   - guardrails       : ~/.local/bin/ command wrappers (no /etc/, no sudo)
#   - desktop-session  : KDE Plasma 6 user-timer watchdog + user systemd drop-ins
#   - orphan-reaper    : ~/.local/bin/ engine + ~/.config/ whitelist
#
# Removed 2026-06-10 (duplicated by NixOS host; broke on every switch with
# "Read-only file system" against /etc/systemd/system/):
#   - system-protection-layer2-identity.nix    → systemd.slices.* in host
#   - system-protection-resource-bouncer.nix   → services.earlyoom + sysctl in host
#   - system-protection-watchdog-dropbear.nix  → systemd.services.{disk-*,rescue-ssh}
{ config, pkgs, lib, ... }:

{
  imports = [
    ./system-protection-guardrails.nix
    ./system-protection-desktop-session.nix
    ./system-protection-orphan-reaper.nix
    ./mem-reclaim.nix
  ];
}
