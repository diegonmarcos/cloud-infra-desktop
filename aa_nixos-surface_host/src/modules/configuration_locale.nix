# Timezone, locale, console keymap, fonts
{ config, pkgs, lib, ... }:

{
  # ═══════════════════════════════════════════════════════════════════════════
  # TIMEZONE AND LOCALE
  # ═══════════════════════════════════════════════════════════════════════════

  # Automatic timezone based on location (uses geoclue)
  time.timeZone = null;
  services.geoclue2 = {
    enable = true;
    enableDemoAgent = lib.mkForce true;
    geoProviderUrl = "https://beacondb.net/v1/geolocate";
  };
  services.automatic-timezoned.enable = true;
  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ALL = "en_GB.UTF-8";
    LANG = "en_GB.UTF-8";
  };
  i18n.supportedLocales = [
    "en_GB.UTF-8/UTF-8"   # British English (international date format DD/MM/YYYY)
    "en_US.UTF-8/UTF-8"   # American English
    "es_ES.UTF-8/UTF-8"   # Spanish
    "pt_PT.UTF-8/UTF-8"   # Portuguese
    "pt_BR.UTF-8/UTF-8"   # Brazilian Portuguese
    "de_DE.UTF-8/UTF-8"   # German
  ];

  # Console (TTY) keyboard layout - Spanish
  console.keyMap = "es";

  # ═══════════════════════════════════════════════════════════════════════════
  # FONTS (Minimal set for GUI)
  # ═══════════════════════════════════════════════════════════════════════════

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-emoji
    liberation_ttf
    jetbrains-mono
  ];
}
