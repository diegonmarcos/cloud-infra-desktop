# Networking: NetworkManager, WireGuard, firewall, SSH, avahi, KDE Connect
{ config, pkgs, lib, ... }:

let
  # ── WireGuard endpoint declarations (data-driven) ──────────────────────────
  # Single source of truth for hub host/port + fallback port.
  # Mirrors cloud/config.json#native.wireguard. Edit the JSON, not the .nix.
  wgData = builtins.fromJSON (builtins.readFile ./wireguard-endpoints.json);
  wgPrimary  = "${wgData.hub.host}:${toString wgData.hub.primary.port}";
  wgFallback = "${wgData.hub.host}:${toString wgData.hub.fallback.port}";

  # ── WireGuard PUBLIC endpoint declarations (zany-popping plan Phase 1) ─────
  # Second WG interface — wg-public (10.1.0.0/24 on udp/51821, hub = oci-analytics).
  # Mirrors cloud/config.json#native.wireguard_public. Distinct subnet + port
  # from wg0; allows the laptop to reach public-trust services without exposing
  # private wg0 surface. Edit the JSON, not the .nix.
  wgPublicData    = builtins.fromJSON (builtins.readFile ./wireguard-public-endpoints.json);
  wgPublicPrimary = "${wgPublicData.hub.host}:${toString wgPublicData.hub.primary.port}";

  # Helper: switch the running wg0 endpoint between primary and fallback
  # without rebuilding NixOS. Reads the JSON above so ports are never
  # hardcoded inside the script.
  wg-fallback = pkgs.writeShellApplication {
    name = "wg-fallback";
    runtimeInputs = with pkgs; [ wireguard-tools gawk gnused coreutils iproute2 ];
    text = ''
      set -euo pipefail
      MODE="''${1:-status}"
      IFACE="${wgData.client.interface}"
      HUB_HOST="${wgData.hub.host}"
      PRIMARY_PORT="${toString wgData.hub.primary.port}"
      FALLBACK_PORT="${toString wgData.hub.fallback.port}"
      HUB_PUBKEY="${wgData.hub.wg_public_key}"

      case "$MODE" in
        status)
          if ! sudo wg show "$IFACE" >/dev/null 2>&1; then
            echo "[wg-fallback] $IFACE is DOWN"; exit 0
          fi
          # Field-equality match (NOT regex): the WG pubkey contains '/' and '+'
          # which break an awk /regex/ delimiter. `wg show endpoints` emits
          # "<pubkey>\t<endpoint>" so match $1 literally.
          CUR=$(sudo wg show "$IFACE" endpoints | awk -v k="$HUB_PUBKEY" '$1==k{print $2}')
          echo "[wg-fallback] $IFACE endpoint: ''${CUR:-unknown}"
          echo "[wg-fallback] primary  = $HUB_HOST:$PRIMARY_PORT"
          echo "[wg-fallback] fallback = $HUB_HOST:$FALLBACK_PORT (udp/443 -> udp/$PRIMARY_PORT NAT on hub)"
          ;;
        primary|fallback)
          PORT="$PRIMARY_PORT"
          [ "$MODE" = "fallback" ] && PORT="$FALLBACK_PORT"
          echo "[wg-fallback] switching $IFACE to $HUB_HOST:$PORT ($MODE)"
          sudo wg set "$IFACE" peer "$HUB_PUBKEY" endpoint "$HUB_HOST:$PORT"
          # Force handshake refresh
          sudo wg set "$IFACE" peer "$HUB_PUBKEY" persistent-keepalive 25
          sleep 2
          sudo wg show "$IFACE" latest-handshakes
          ;;
        *)
          echo "Usage: wg-fallback {status|primary|fallback}" >&2
          exit 1
          ;;
      esac
    '';
  };
in {
  # ═══════════════════════════════════════════════════════════════════════════
  # NETWORKING
  # ═══════════════════════════════════════════════════════════════════════════

  networking = {
    hostName = "surface-nixos";
    networkmanager.enable = lib.mkDefault true;  # ISO disables this
    firewall = {
      enable = lib.mkDefault true;
      # No globally-open ports. SSH (22) is wg0-only via `trustedInterfaces`
      # below — anyone on the local LAN (hostel WiFi etc) cannot reach sshd.
      # See also: configuration_system-protection.nix for rescue dropbear (2200).
      allowedTCPPorts = [];
      trustedInterfaces = [ "wg0" "wg-public" ];  # Allow all traffic on WireGuard meshes (wg0 + wg-public)
    };
  };

  # DNS: tier 2 baseline — Cloudflare + Google (always present)
  # Tier 1 (Hickory) added dynamically by WG postSetup via resolvconf — but ONLY
  # when it's actually reachable (see the guarded postSetup below).
  networking.nameservers = [ "1.1.1.1" "1.0.0.1" "8.8.8.8" ];

  # Resilient resolver (PERMANENT FIX 2026-06-25): a dead tier-1 nameserver (e.g.
  # Hickory 10.0.0.1 when the mesh/gcp-proxy is down) as the FIRST entry stalls
  # EVERY lookup at glibc's default 5s timeout — which broke nixos-rebuild
  # narinfo fetches ("couldn't resolve host"), Waydroid container DNS, and
  # nix-on-droid. 1s timeout + a single re-cycle makes a dead server fail over
  # to the working baseline almost instantly.
  networking.resolvconf.extraConfig = ''
    resolv_conf_options="timeout:1 attempts:2"
  '';

  # WireGuard mesh VPN (on-demand, not auto-start)
  # Hub host/port read from ./wireguard-endpoints.json (data-driven).
  # Default endpoint is the primary port. Switch to fallback at runtime with
  # `wg-fallback fallback` (no NixOS rebuild needed).
  networking.wireguard.interfaces.${wgData.client.interface} = {
    ips = [ "${wgData.client.wg_ip}/24" ];
    privateKeyFile = "/home/diego/.config/wireguard/privatekey";
    # DNS tier 1: Hickory (added when WG up, removed when WG down)
    postSetup = ''
      # Register Hickory (mesh DNS) as tier-1 ONLY if it's actually reachable.
      # A dead 10.0.0.1 as the first nameserver stalls all resolution while the
      # mesh/gcp-proxy is down (the resolv_conf_options above cap the penalty;
      # this avoids it entirely). TCP-probe :53 with a 1s deadline.
      if ${pkgs.netcat-openbsd}/bin/nc -z -w1 ${wgData.hub.wg_ip} 53 2>/dev/null; then
        ${pkgs.openresolv}/bin/resolvconf -a ${wgData.client.interface} <<EOF
      nameserver ${wgData.hub.wg_ip}
      EOF
      else
        echo "[wg0 postSetup] Hickory ${wgData.hub.wg_ip}:53 unreachable — keeping public DNS baseline (mesh down)" >&2
      fi
    '';
    postShutdown = ''
      ${pkgs.openresolv}/bin/resolvconf -d ${wgData.client.interface}
    '';
    peers = [
      {
        publicKey = wgData.hub.wg_public_key;
        endpoint = wgPrimary;          # fallback = "${wgFallback}" (use `wg-fallback fallback`)
        allowedIPs = [ wgData.subnet ];
        persistentKeepalive = wgData.persistent_keepalive;
      }
    ];
  };
  systemd.services."wireguard-${wgData.client.interface}".wantedBy = lib.mkForce [];

  # ── WireGuard PUBLIC mesh (zany-popping plan Phase 1) ──────────────────────
  # Second interface (wg-public, 10.1.0.0/24 on udp/51821) sitting in parallel
  # to wg0. Hub = oci-analytics — reaches the public-trust mesh members
  # (gcp-proxy, oci-mail, oci-apps) for services that should not require wg0.
  # On-demand (NOT auto-started) — bring up with
  #   sudo systemctl start wireguard-wg-public
  # Privatekey is symlinked from vault by the home-manager flake module
  # ba_flakes_desktop/src/modules/cloud-network-wg-public.nix.
  networking.wireguard.interfaces.${wgPublicData.client.interface} = {
    ips = [ "${wgPublicData.client.wg_ip}/24" ];
    privateKeyFile = "/home/diego/.config/wireguard/privatekey-public";
    peers = [
      {
        publicKey = wgPublicData.hub.wg_public_key;
        endpoint = wgPublicPrimary;
        allowedIPs = [ wgPublicData.subnet ];
        persistentKeepalive = wgPublicData.persistent_keepalive;
      }
    ];
  };
  systemd.services."wireguard-${wgPublicData.client.interface}".wantedBy = lib.mkForce [];

  # Runtime endpoint switcher: `wg-fallback {status|primary|fallback}`
  environment.systemPackages = [ wg-fallback ];

  # ═══════════════════════════════════════════════════════════════════════════
  # WIFI & BLUETOOTH PERSISTENCE
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # WiFi: Passwords stored in user's keyring (GNOME Keyring / KWallet)
  #       - Keyring is in ~/.local/share/keyrings/ (portable with home)
  #       - When user logs in, their saved WiFi networks auto-connect
  #       - Each user has their own WiFi passwords (per-user, portable)
  #
  # Bluetooth: Pairings stored in @shared/bluetooth (cross-OS)
  #       - Hardware/adapter-specific, not user-specific
  #       - Symlinked from /var/lib/bluetooth at boot
  #       - Shared between NixOS and any chainloaded OS (Kali, rescue-os-debian)
  #

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # KDE Connect - phone/tablet integration
  programs.kdeconnect.enable = true;

  # KDE Connect clipboard sync workaround for Wayland
  # Monitors clipboard changes and sends to paired device
  # (Fixes "Ignoring clipboard without timestamp" issue on Plasma 6 Wayland)
  #
  # DISABLED: This infinite loop can cause GUI freezes if wl-paste or qdbus hangs.
  # KDE Connect 24.08+ has built-in Wayland clipboard support.
  # If you need this, enable it manually or use kdeconnect-indicator instead.
  #
  # systemd.user.services.kdeconnect-clipboard-sync = {
  #   description = "KDE Connect Clipboard Sync (Wayland workaround)";
  #   wantedBy = [ "graphical-session.target" ];
  #   after = [ "graphical-session.target" ];
  #   serviceConfig = {
  #     Type = "simple";
  #     Restart = "on-failure";
  #     RestartSec = 5;
  #     ExecStart = pkgs.writeShellScript "kdeconnect-clipboard-sync" ''
  #       LAST_CLIP=""
  #       while true; do
  #         CURRENT_CLIP=$(${pkgs.wl-clipboard}/bin/wl-paste 2>/dev/null)
  #         if [[ "$CURRENT_CLIP" != "$LAST_CLIP" && -n "$CURRENT_CLIP" ]]; then
  #           ${pkgs.kdePackages.qttools}/bin/qdbus org.kde.kdeconnect \
  #             /modules/kdeconnect/devices/*/clipboard \
  #             org.kde.kdeconnect.device.clipboard.sendClipboard "$CURRENT_CLIP" 2>/dev/null || true
  #           LAST_CLIP="$CURRENT_CLIP"
  #         fi
  #         sleep 1
  #       done
  #     '';
  #   };
  # };

  # ═══════════════════════════════════════════════════════════════════════════
  # SSH (Ephemeral host keys - regenerate each boot)
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # Host keys regenerate on every boot (stored in tmpfs).
  # This means SSH clients will see "host key changed" warnings.
  # For a Surface tablet used as personal device, this is acceptable.
  # Alternative: persist host keys in @shared/ssh/ via tmpfiles symlink if needed.

  services.openssh = {
    enable = true;
    # Don't auto-open port 22 globally; rely on `trustedInterfaces = ["wg0"]`
    # in networking.firewall above so SSH is wg0-only (LAN cannot reach it).
    openFirewall = false;
    # wg0-ONLY at the SOCKET level (2026-06-15, owner: "SSH only on wg0, no
    # public"). Binding to the wg0 IP means sshd never even listens on the LAN,
    # public, or wg-public — defense-in-depth on top of the firewall. Data-driven
    # from wireguard-endpoints.json. sshd is ordered After wireguard-wg0.service
    # (below) so the address exists before it binds. If wg0 is down, sshd refuses
    # to start (remote SSH unavailable; local console always works) — intended.
    listenAddresses = [ { addr = wgData.client.wg_ip; port = 22; } ];
    settings = {
      PasswordAuthentication = false;   # key-only (was true). Owner: no password SSH.
      KbdInteractiveAuthentication = false;
      PermitRootLogin = lib.mkDefault "no";  # ISO installer overrides to "yes"
      # Lynis SSH-7408 hardening — even though SSH is wg0-only, defense-in-depth
      # against a compromised wg0 peer or laptop boot in untrusted env.
      MaxAuthTries        = 3;        # was 6 — cuts brute-force window
      MaxSessions         = 2;        # was 10 — one user per conn at most
      ClientAliveCountMax = 2;        # was 3 — drop dead conns sooner
      LogLevel            = "VERBOSE";# was INFO — better forensic trail
      X11Forwarding       = false;    # already off; pin it
      AllowTcpForwarding  = false;    # was yes — no SSH tunneling
      AllowAgentForwarding = false;   # was yes — prevents agent hijack
      TCPKeepAlive        = false;    # was yes — use ClientAlive instead
    };
    # Let NixOS generate ephemeral keys to /etc/ssh (tmpfs)
    # Remove hostKeys to use default ephemeral behavior
  };

  # sshd binds the wg0 address (listenAddresses above) — it MUST start after the
  # wg0 interface exists or the bind fails at boot. Order it after the wireguard
  # tunnel unit (2026-06-15). The interface unit is "active (exited)" once the
  # address is configured.
  systemd.services.sshd = {
    after = [ "wireguard-wg0.service" ];
    wants = [ "wireguard-wg0.service" ];
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # KERNEL ATTACK SURFACE (Lynis NETW-3200) — blacklist rare network protocols
  # ═══════════════════════════════════════════════════════════════════════════
  # These protocols are loadable kernel modules with their own CVE histories
  # (e.g. SCTP CVE-2019-8956, TIPC CVE-2022-0435). You almost certainly never
  # use any of them on a desktop — blacklisting closes the autoload-on-syscall
  # path that worms can use for kernel-level exploitation.
  boot.blacklistedKernelModules = [
    "dccp"   # Datagram Congestion Control Protocol
    "sctp"   # Stream Control Transmission Protocol
    "rds"    # Reliable Datagram Sockets
    "tipc"   # Transparent Inter-Process Communication
  ];
}
