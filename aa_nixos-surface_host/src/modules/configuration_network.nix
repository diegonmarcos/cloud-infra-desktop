# Networking: NetworkManager, WireGuard, firewall, SSH, avahi, KDE Connect
{ config, pkgs, lib, ... }:

{
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
      trustedInterfaces = [ "wg0" ];  # Allow all traffic on WireGuard mesh
    };
  };

  # DNS: tier 2 baseline — Cloudflare + Google (always present)
  # Tier 1 (Hickory) added dynamically by WG postSetup via resolvconf
  networking.nameservers = [ "1.1.1.1" "1.0.0.1" "8.8.8.8" ];

  # WireGuard mesh VPN (on-demand, not auto-start)
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.0.0.5/24" ];
    privateKeyFile = "/home/diego/.config/wireguard/privatekey";
    # DNS tier 1: Hickory (added when WG up, removed when WG down)
    postSetup = ''
      ${pkgs.openresolv}/bin/resolvconf -a wg0 <<EOF
      nameserver 10.0.0.1
      EOF
    '';
    postShutdown = ''
      ${pkgs.openresolv}/bin/resolvconf -d wg0
    '';
    peers = [
      {
        publicKey = "vV/phXUwnCjxACQ5Df11Uw47BzJaK4r85jPYMu2HmDc=";
        endpoint = "35.226.147.64:51820";
        allowedIPs = [ "10.0.0.0/24" ];
        persistentKeepalive = 25;
      }
    ];
  };
  systemd.services.wireguard-wg0.wantedBy = lib.mkForce [];

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
    settings = {
      PasswordAuthentication = true;
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
