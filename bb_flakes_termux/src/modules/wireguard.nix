# WireGuard configuration for Termux (Android)
# Creates symlinks from vault to ~/.config/wireguard/
#
# Two endpoint variants (Phase 4 hub-side NAT redirect on gcp-proxy):
#   wg0.conf          -> vault/termux/config            (Endpoint = HUB:51820, primary)
#   wg0-fallback.conf -> vault/termux/config-fallback   (Endpoint = HUB:443,   fallback)
#
# Switch at runtime (no rebuild):
#   wg-quick down wg0          && wg-quick up wg0-fallback   # primary -> fallback
#   wg-quick down wg0-fallback && wg-quick up wg0            # fallback -> primary
#
# The vault-side file vault/A0_keys/providers/wireguard/termux/config-fallback
# must exist (same as `config` but with `Endpoint = 35.226.147.64:443`).
{ config, pkgs, lib, ... }:

let
  # ~/git/cloud-vault — the SAME path every other module uses (common.nix, the
  # curl/wget wrappers, claude settings env). The old value pointed at
  # ~/storage/shared/git/cloud-vault/… which doesn't exist, so every symlink
  # below dangled and "[wireguard-wstunnel] wg0.conf not found — skipping
  # render" fired on every switch since day one (found 2026-08-08).
  vaultBase = "${config.home.homeDirectory}/git/cloud-vault/A0_keys/providers/wireguard";
in
{
  home.file.".config/wireguard/privatekey" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux/privatekey";
  };

  home.file.".config/wireguard/publickey" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux/publickey";
  };

  # ── EXACTLY FOUR PROFILES (2026-08-20 consolidation): family × tunnel ─────
  # Matrix: {v4,v6 network} × {split,full tunnel}. All share one identity
  # (termux key, 10.0.0.9 / 10.1.0.9 / fd0c:1d01::9) and carry BOTH hub peers.
  # DNS is MESH-ONLY everywhere — hickory 10.0.0.1 (via gcp-proxy) + unbound
  # 10.1.0.1 / fd0c:1d01::1 (via oci-analytics): two resolvers over two hubs
  # is the redundancy; no external resolver (Cloudflare) anywhere.
  #   *-split: only mesh subnets (+NAT64 /96) tunneled; internet on raw wifi.
  #   *-full:  0.0.0.0/0 + ::/0 tunneled (v4-full: v4 via gcp-proxy, v6 via
  #            oci-analytics; v6-full: everything via oci-analytics DNS64+NAT64).
  # Names ≤15 chars — the WG app rejects longer tunnel names on import.
  home.file.".config/wireguard/wg-v4-split.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/config-v4-split";
  };

  home.file.".config/wireguard/wg-v4-full.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/config-v4-full";
  };

  home.file.".config/wireguard/wg-v6-split.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/config-v6-split";
  };

  home.file.".config/wireguard/wg-v6-full.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/config-v6-full";
  };

  # ── WireGuard PUBLIC mesh client (zany-popping plan Phase 1) ──────────────
  # Termux phone joins the wg-public mesh (10.1.0.0/24, hub = oci-analytics) as
  # a client peer in addition to wg0. Bring up with:
  #   wg-quick up wg-public
  # Vault key dir: vault/A0_keys/providers/wireguard/termux-public/
  # Source-of-truth peer table: ~/git/cloud-infra/1_cloud-configs/dist/build-flakes_termux.json
  #                             .wireguard_public.{peers,clients.termux}
  home.file.".config/wireguard/privatekey-public" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/privatekey";
  };

  home.file.".config/wireguard/publickey-public" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/publickey";
  };


  # ── Mirror the profiles into Android shared storage ──────────────────────
  # The WireGuard app cannot see Termux's home dir, so the profiles have to land
  # on /storage/emulated/0 to be importable. Same layout as the home dir:
  #   ~/.config/wireguard/*.conf  ->  /storage/emulated/0/.config/wireguard/*.conf
  # Same filenames, so the two trees are a straight mirror.
  #
  # REAL COPIES, never symlinks: the sdcardfs/FUSE mount backing shared storage
  # rejects symlink(2) outright ("Permission denied"), so mkOutOfStoreSymlink and
  # home.file cannot target it at all. cp -L follows the store symlink and writes
  # the vault file's actual bytes. Verified on-device.
  #
  # The copies carry the live PrivateKey into world-readable storage, where any
  # app holding storage permission can read them. That is inherent to importing
  # into the app; delete the mirror once the profiles are in the app if that
  # trade is not worth it.
  home.activation.mirrorWireguardToSharedStorage =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mirrorDir="$HOME/storage/.config/wireguard"
      if ! ${pkgs.coreutils}/bin/mkdir -p "$mirrorDir" 2>/dev/null; then
        echo "[wireguard] shared storage unavailable — skipping mirror (run termux-setup-storage?)"
      else
        # SYNC, not accumulate: delete every mirrored .conf first so profiles
        # removed from the module actually disappear from the phone (stale
        # split-tunnel profiles kept getting re-imported from here).
        ${pkgs.coreutils}/bin/rm -f "$mirrorDir"/*.conf
        for src in "$HOME"/.config/wireguard/*.conf; do
          # -r also filters out symlinks left dangling by a missing vault file.
          [ -r "$src" ] || { echo "[wireguard] $src missing/dangling — not mirrored"; continue; }
          ${pkgs.coreutils}/bin/cp -L -f "$src" "$mirrorDir/$(${pkgs.coreutils}/bin/basename "$src")"
          echo "[wireguard] mirrored $(${pkgs.coreutils}/bin/basename "$src")"
        done
      fi
    '';

  home.sessionVariables = {
    WIREGUARD_IP = "10.0.0.9";
    WIREGUARD_PUBLIC_IP = "10.1.0.9";
  };
}
