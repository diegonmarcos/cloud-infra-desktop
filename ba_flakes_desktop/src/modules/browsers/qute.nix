# qutebrowser — DEDICATED declarative module.
#
# Daily-driver browser intended to pair with the FIDO2 + autofill daemons:
#   * da_fido2-vault-broker (virtual FIDO2 device on /dev/uhid → Chromium
#     discovers /dev/hidraw5 automatically; no extension wiring).
#   * da_autofill-rbw-rofi (system-wide hotkey password autofill).
#
# Config is JSON-driven (settings / search engines / keybindings / quickmarks)
# and lives in the daemon repo at ~/git/unix/da_browser-qute/src/2_configs/.
# The home-manager module shipped from that repo reads the JSON at flake
# evaluation and projects it into `programs.qutebrowser`.
#
# We import the daemon's home-manager module via its relative path inside
# the unix/ monorepo — no flake input needed since both projects live here.
#
# Imported by: modules/profiles/<your-productivity-profile>.nix
#              (registered as "browsers/qute" in modules/leaves.json).

{ ... }:

{
  imports = [ ../../../../da_browser-qute/src/nix/home-module.nix ];

  programs.da_browser-qute = {
    enable = true;
    # Stay non-default for now — keep Brave as the system default until the
    # qute config has had real-world miles. Operator can flip this later.
    defaultBrowser = false;
  };
}
