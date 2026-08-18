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

  home.file.".config/wireguard/wg0.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux/config";
  };

  # Phase 4 fallback (udp/443 -> udp/51820 NAT on gcp-proxy)
  home.file.".config/wireguard/wg0-fallback.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux/config-fallback";
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

  # No pathExists gate: the closure is built in CI where the device path
  # never exists, so the mkIf was permanently false and wg-public.conf was
  # never deployed. mkOutOfStoreSymlink tolerates a missing target (the
  # symlink just dangles until the vault file appears).
  #
  # ONE FILE PER MESH. This is the wg-public-only profile, the counterpart to
  # wg0.conf above. It previously pointed at termux-public/config — but that
  # vault file is the MERGED two-peer profile ("WireGuard MERGED (wg0 +
  # wg-public)" per its own header), so the name promised a per-mesh profile and
  # delivered a merged one. The merged variants are deployed separately below.
  home.file.".config/wireguard/wg-public.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/config-public-only";
  };

  # ── MERGED profiles (both meshes on one interface) ───────────────────────
  # Android grants exactly one VpnService slot, so wg0.conf and wg-public.conf
  # above can both be imported but only ONE can be active. These merged profiles
  # are the way to have both meshes up simultaneously: single interface, two
  # peers, one shared identity.
  #
  # Two variants because a WireGuard peer carries exactly ONE endpoint — a single
  # sockaddr, not a list. No happy-eyeballs, no A/AAAA racing, no retry on the
  # other family. So one .conf cannot serve both an IPv4-only and an IPv6-only
  # network; you switch profiles by hand.
  #   ipv4 -> oci-analytics over 129.151.228.66, split tunnel (safe default)
  #   ipv6 -> oci-analytics over its Oracle v6 literal, 0.0.0.0/0 + ::/0 so the
  #           hub's Unbound-DNS64 + Tayga NAT64 can reach IPv4-only sites.
  home.file.".config/wireguard/wg0-wgP-ipv4.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/config-ipv4";
  };

  home.file.".config/wireguard/wg0-wgP-ipv6.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${vaultBase}/termux-public/config";
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
