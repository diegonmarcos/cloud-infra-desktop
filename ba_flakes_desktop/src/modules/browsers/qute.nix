# qutebrowser — DEDICATED declarative module.
#
# Daily-driver browser intended to pair with the FIDO2 + autofill daemons:
#   * da_fido2-vault-broker (virtual FIDO2 device on /dev/uhid → Chromium
#     discovers /dev/hidraw5 automatically; no extension wiring).
#   * da_autofill-rbw-rofi (system-wide hotkey password autofill).
#
# Config is JSON-driven (settings / search engines / keybindings / quickmarks)
# and lives in the daemon repo at ~/git/unix/da_my-browser-qute/src/2_configs/.
# The home-manager module shipped from that repo reads the JSON at flake
# evaluation and projects it into `programs.qutebrowser`.
#
# We import the daemon's home-manager module via the `unix-repo` flake input
# (declared in flake.nix, pinned to a github commit of diegonmarcos/unix).
# Using a flake input — not a relative `..` traversal — keeps the import
# portable across all flake ref styles and avoids escaping the flake source
# dir at eval time.
#
# Imported by: modules/profiles/<your-productivity-profile>.nix
#              (registered as "browsers/qute" in modules/leaves.json).

{ inputs, ... }:

{
  imports = [ "${inputs.unix-repo}/da_my-browser-qute/src/nix/home-module.nix" ];

  programs.my-browser = {
    enable = true;
    # Stay non-default for now — keep Brave as the system default until the
    # qute config has had real-world miles. Operator can flip this later.
    defaultBrowser = false;
  };
}
