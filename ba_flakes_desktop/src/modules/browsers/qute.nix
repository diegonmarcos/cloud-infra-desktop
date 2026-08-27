# my-browser-qute — DEDICATED declarative module.
#
# Daily-driver browser intended to pair with the FIDO2 + autofill daemons:
#   * db_fido2-vault-broker (virtual FIDO2 device on /dev/uhid → Chromium
#     discovers /dev/hidraw5 automatically; no extension wiring).
#   * da_autofill-rbw-rofi (system-wide hotkey password autofill).
#
# Config is JSON-driven (settings / search engines / keybindings / quickmarks)
# and lives in the daemon repo at ~/git/cloud-unix/db_my-browser-qute/src/2_configs/.
# The home-manager module shipped from that repo reads the JSON at flake
# evaluation and renders it into ~/.config/my-browser-qute/config.py itself
# (it no longer goes through home-manager's `programs.qutebrowser`, which
# hard-codes ~/.config/qutebrowser).
#
# We import the daemon's home-manager module via the `unix-repo` flake input
# (declared in flake.nix, pinned to a github commit of diegonmarcos/cloud-unix).
# Using a flake input — not a relative `..` traversal — keeps the import
# portable across all flake ref styles and avoids escaping the flake source
# dir at eval time.
#
# Imported by: modules/profiles/<your-productivity-profile>.nix
#              (registered as "browsers/qute" in modules/leaves.json).

{ inputs, ... }:

{
  imports = [ "${inputs.unix-repo}/db_my-browser-qute/src/nix/home-module.nix" ];

  programs.my-browser = {
    enable = true;
    # Stay non-default for now — keep Brave as the system default until the
    # my-browser-qute config has had real-world miles. Operator can flip this later.
    defaultBrowser = false;
  };
}
