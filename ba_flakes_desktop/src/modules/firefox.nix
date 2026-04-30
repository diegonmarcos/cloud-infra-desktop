# Firefox — DEDICATED declarative module with Vulkan-backed WebGPU.
#
# DESIGN: ONE firefox binary, env vars set globally so plain `firefox`
# always launches with the full hardware-acceleration stack:
#   - Wayland-native rendering (no XWayland)
#   - WebGPU via wgpu's Vulkan backend (Mesa intel_icd / ANV)
#   - WebRender compositor on GPU
#   - VAAPI hardware video decode (RDD sandbox relaxed)
#   - Intel iGPU render node pinned explicitly
#
# Why no separate firefox-vulkan wrapper (unlike brave-opengl):
#   Firefox's Vulkan toggle is purely env-var driven (Mozilla designed it
#   that way). With these env vars set in home.sessionVariables, KDE/SDDM
#   propagates them to all graphical apps including firefox launches from
#   KRunner/taskbar/.desktop. No need to physically separate the binary.
#
#   Brave needed --ozone-platform=x11 (a CLI flag, not env-var-controllable),
#   AND needed a unique /proc/PID/exe so KDE could distinguish pinned
#   variants. Hence the heavy two-derivation approach. Firefox doesn't.
#
# Imported by: modules/profiles/7-productivity.nix
#
{ config, pkgs, lib, ... }:
let
  # Force-installed extensions, mirrored from brave-extensions.json schema.
  # Source of truth: ./firefox-extensions.json
  extCfg = builtins.fromJSON (builtins.readFile ./firefox-extensions.json);
  realExtensions = lib.filterAttrs (n: _: !(lib.hasPrefix "$" n)) extCfg.extensions;

  # Build the ExtensionSettings policy from JSON. force_installed +
  # install_url pointing at AMO's "latest.xpi" redirect → always latest
  # stable, auto-updates. installation_mode=force_installed prevents the
  # user from removing the extension via the UI (matches Brave's force-
  # installed behaviour from External Extensions/<id>.json).
  mkExtensionPolicy = id: meta: lib.nameValuePair id {
    installation_mode = "force_installed";
    install_url = "https://addons.mozilla.org/firefox/downloads/latest/${meta.slug}/latest.xpi";
  };
  extensionPolicies = lib.mapAttrs' mkExtensionPolicy realExtensions;
in
{
  programs.firefox = {
    enable = true;
    package = pkgs.firefox;

    # Enterprise policies — written to firefox/distribution/policies.json,
    # applied on every Firefox start regardless of how it's launched.
    # Don't touch user profile data, so existing bookmarks/logins survive.
    policies = {
      # Permit WebGPU API to be exposed (still gated by dom.webgpu.enabled
      # in about:config; the policy just allows the user to enable it).
      EnableWebGPU = true;
      # Hardware acceleration must stay on
      DisableHardwareAcceleration = false;
      # Match Brave's homepage behaviour
      Homepage = {
        URL = "http://localhost:8000";
        StartPage = "homepage";
      };
      # Force-install extensions matching brave-extensions.json (subset
      # that has Firefox counterparts on AMO). Source of truth:
      # ./firefox-extensions.json.
      ExtensionSettings = extensionPolicies // {
        # Wildcard: allow user to install ADDITIONAL extensions from AMO
        # beyond the declared force-installed set.
        "*" = { installation_mode = "allowed"; };
      };

      # Pref overrides — equivalent of about:config but applied via policy
      # so it lands on every profile without needing a manual user toggle.
      # Status="default" means it's the default; user can still override
      # interactively. Use Status="locked" to prevent override.
      #
      # Mozilla's Preferences policy supports a whitelisted subset of
      # about:config keys. If a key isn't supported, the policy silently
      # no-ops. As of Firefox 140, dom.webgpu.* + gfx.webrender.* + media.*
      # prefs in this set are accepted; verify after rebuild via
      # about:policies (lists active policies and which were ignored).
      Preferences = {
        # WebGPU API exposed to JavaScript by default — combined with
        # WGPU_BACKEND=vulkan env var, this gives full Vulkan WebGPU.
        "dom.webgpu.enabled" = { Value = true; Status = "default"; };
        # WebGPU workers (lets WebGPU run inside web workers / OffscreenCanvas).
        "dom.webgpu.workers.enabled" = { Value = true; Status = "default"; };
        # Force WebRender on even if Mesa is on a banlist for this GPU.
        "gfx.webrender.all" = { Value = true; Status = "default"; };
        # Use the OS compositor for WebRender output (passes frames to KWin).
        "gfx.webrender.compositor.force-enabled" = { Value = true; Status = "default"; };
        # VAAPI hardware video decode through ffmpeg (paired with the
        # MOZ_DISABLE_RDD_SANDBOX env var).
        "media.ffmpeg.vaapi.enabled" = { Value = true; Status = "default"; };
        "media.hardware-video-decoding.force-enabled" = { Value = true; Status = "default"; };
        # AV1 decoding (often hardware on Tiger Lake; software-decoded otherwise).
        "media.av1.enabled" = { Value = true; Status = "default"; };
      };
    };
  };

  # Env vars that switch every firefox launch into the Vulkan/Wayland/VAAPI
  # path. SDDM sources home.sessionVariables on graphical login → these
  # apply to firefox launched from terminal AND from KRunner/taskbar/menu.
  home.sessionVariables = {
    # Wayland-native rendering — no XWayland, gets KWin compositor directly.
    # Firefox handles this path correctly on KWin (unlike Chromium).
    MOZ_ENABLE_WAYLAND = "1";
    # Force WebRender compositor (default in 121+, explicit for clarity).
    MOZ_WEBRENDER = "1";
    # Use EGL (not GLX) on X11 fallback — needed for VAAPI in that mode.
    MOZ_X11_EGL = "1";
    # Allow the RDD process to access /dev/dri/renderD128 — without this,
    # hardware VAAPI video decode silently falls back to software decode.
    MOZ_DISABLE_RDD_SANDBOX = "1";
    # Tell wgpu (Firefox's WebGPU library) to prefer the Vulkan backend.
    # On Linux + Mesa intel_icd (ANV), this routes WebGPU through Vulkan
    # — the path Brave can't reach on KWin XWayland.
    WGPU_BACKEND = "vulkan";
    # Pin the render node device explicitly to the Intel iGPU.
    MOZ_DRM_DEVICE = "/dev/dri/renderD128";
  };
}
