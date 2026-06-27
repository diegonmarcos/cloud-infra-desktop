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
  # Base/fallback resolver = the LOCAL encrypted proxy (dnscrypt-proxy2 below) on
  # 127.0.0.1:53, which forwards to Cloudflare/Google over DoH/DoT (:443/:853).
  # This survives networks that block plain outbound :53 (e.g. wificasa) and is
  # private. Hickory (10.0.0.1) is still added first by the wg0 NM profile
  # (dns-priority 50) for internal names when wg0 is up; when wg0/Hickory is down,
  # resolution falls through to 127.0.0.1 → encrypted public DNS.
  # systemd-resolved: the DNS backend that actually honours NM per-interface
  # dns-priority. With the old resolvconf backend, NM's dns-priority=50 on wg0
  # never propagated to /etc/resolv.conf (networking.nameservers="127.0.0.1"
  # owned it statically). systemd-resolved stub on 127.0.0.53 is the system
  # resolver; /etc/resolv.conf → symlink → 127.0.0.53.
  services.resolved = {
    enable = true;
    dnssec = "false";      # dnscrypt-proxy2 handles DNSSEC upstream
    # Global DNS = dnscrypt-proxy2 (encrypted DoH/DoT to Cloudflare/Google).
    # wg0's Hickory (10.0.0.1) is registered by NM per-interface and is used
    # ONLY for ~diegonmarcos.com routing domain (see wg0 profile below).
    fallbackDns = [ "1.1.1.1" "9.9.9.9" ];  # bare fallback if dnscrypt-proxy2 down
    extraConfig = ''
      DNS=127.0.0.1
    '';
  };
  networking.networkmanager.dns = "systemd-resolved";

  # ═══════════════════════════════════════════════════════════════════════════
  # Encrypted DNS — local dnscrypt-proxy2 on 127.0.0.1:53 (DoH/DoT over :443/:853)
  # ═══════════════════════════════════════════════════════════════════════════
  # The system fallback resolver (networking.nameservers above) points here. It
  # tunnels DNS over HTTPS to Cloudflare/Google, so it works on networks that
  # block plain outbound :53 (wificasa) and keeps queries private. Caches results
  # and load-balances across the chosen resolvers. The public-resolvers source
  # list is provided by the module's upstreamDefaults and cached in
  # /var/lib/dnscrypt-proxy (fetched once over HTTPS).
  services.dnscrypt-proxy2 = {
    enable = true;
    settings = {
      listen_addresses = [ "127.0.0.1:53" ];
      ipv6_servers = true;
      require_dnssec = true;
      # Prefer DoH/DoT public resolvers (encrypted). Cloudflare + Google + Quad9.
      server_names = [ "cloudflare" "google" "quad9-dnscrypt-ip4-filter-pri" ];
      cache = true;
      # Bootstrap (resolve the resolver-list source host on first run / list refresh).
      # Plain :53 here is only used to fetch the HTTPS source list when possible;
      # actual queries go out encrypted over :443/:853.
      bootstrap_resolvers = [ "1.1.1.1:53" "9.9.9.9:53" ];
      ignore_system_dns = true;
      netprobe_timeout = 0;   # don't block startup waiting for connectivity
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # WireGuard meshes — NetworkManager-managed (visible + toggleable in plasma-nm)
  # ═══════════════════════════════════════════════════════════════════════════
  # wg0 (private mesh, hub gcp-proxy) + wg-public (public mesh, hub oci-analytics)
  # are declared as NetworkManager profiles so they show up in the KDE network
  # applet. Endpoint/IP/subnet data is read from ./wireguard-endpoints.json and
  # ./wireguard-public-endpoints.json (data-driven — edit the JSON, not this).
  #
  # Private keys NEVER touch the world-readable nix store: the profiles carry
  # $WG0_PRIVATE_KEY / $WGPUB_PRIVATE_KEY placeholders that NM's envsubst step
  # resolves from /run/nm-wg-secrets.env (root-only, tmpfs), generated at boot by
  # nm-wg-secrets.service below from the vault-deployed keys.
  #
  # `interface-name` pins the kernel devices to "wg0"/"wg-public" so the firewall
  # `trustedInterfaces` rule above keeps matching. autoconnect = both tunnels
  # come up on every network (also gives wg0 Hickory 10.0.0.1 as DNS, bypassing
  # captive/ISP networks that block outbound :53).
  networking.networkmanager.ensureProfiles = {
    environmentFiles = [ "/run/nm-wg-secrets.env" ];
    profiles = {
      "wg0" = {
        connection = {
          id = "wg0";
          type = "wireguard";
          interface-name = wgData.client.interface;
          autoconnect = "true";
        };
        wireguard.private-key = "$WG0_PRIVATE_KEY";
        "wireguard-peer.${wgData.hub.wg_public_key}" = {
          endpoint = wgPrimary;
          allowed-ips = wgData.subnet;
          persistent-keepalive = toString wgData.persistent_keepalive;
        };
        ipv4 = {
          method = "manual";
          address1 = "${wgData.client.wg_ip}/24";
          dns = wgData.hub.wg_ip;        # Hickory mesh DNS for diegonmarcos.com
          dns-priority = "50";
          # ~diegonmarcos.com = routing domain: systemd-resolved routes ONLY
          # *.diegonmarcos.com queries to Hickory (10.0.0.1). All other queries
          # continue to use the global DNS (127.0.0.1 = dnscrypt-proxy2).
          # Without this, dns-priority=50 would make Hickory the global primary
          # resolver (before dnscrypt-proxy2), but Hickory only knows diegonmarcos.com.
          dns-search = "~diegonmarcos.com";
          never-default = "true";        # only route the mesh subnet, not all traffic
        };
        ipv6.method = "ignore";
      };
      "wg-public" = {
        connection = {
          id = "wg-public";
          type = "wireguard";
          interface-name = wgPublicData.client.interface;
          autoconnect = "true";
        };
        wireguard.private-key = "$WGPUB_PRIVATE_KEY";
        "wireguard-peer.${wgPublicData.hub.wg_public_key}" = {
          endpoint = wgPublicPrimary;
          allowed-ips = wgPublicData.subnet;
          persistent-keepalive = toString wgPublicData.persistent_keepalive;
        };
        ipv4 = {
          method = "manual";
          address1 = "${wgPublicData.client.wg_ip}/24";
          dns-search = "";
          never-default = "true";
        };
        ipv6.method = "ignore";
      };
    };
  };

  # Materialise the root-only env file with the WG private keys for NM's envsubst.
  # Reads the home-manager-deployed keys at ~/.config/wireguard/ (symlinks into
  # the vault). Ordered BEFORE NM applies the declarative profiles.
  systemd.services.nm-wg-secrets = {
    description = "Generate NetworkManager WireGuard private-key env file";
    wantedBy = [ "NetworkManager-ensure-profiles.service" ];
    before = [ "NetworkManager-ensure-profiles.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0177";
    };
    path = [ pkgs.coreutils ];
    script = ''
      OUT=/run/nm-wg-secrets.env
      : > "$OUT"
      chmod 0600 "$OUT"
      WG0_KEY=/home/diego/.config/wireguard/privatekey
      WGPUB_KEY=/home/diego/.config/wireguard/privatekey-public
      [ -r "$WG0_KEY" ]   && printf 'WG0_PRIVATE_KEY=%s\n'   "$(tr -d '\n\r' < "$WG0_KEY")"   >> "$OUT"
      [ -r "$WGPUB_KEY" ] && printf 'WGPUB_PRIVATE_KEY=%s\n' "$(tr -d '\n\r' < "$WGPUB_KEY")" >> "$OUT"
    '';
  };

  # Runtime endpoint switcher: `wg-fallback {status|primary|fallback}`
  # NOTE: with NM-managed wg0, a `wg set` endpoint tweak survives only until NM
  # reactivates the profile; for a permanent fallback port, edit the profile +
  # rebuild. The `status` subcommand still works as-is for quick inspection.
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

  # sshd binds the wg0 address (listenAddresses above) — it MUST start after wg0
  # exists or the bind fails at boot. wg0 is now NetworkManager-managed (autoconnect),
  # so order sshd after NM has finished bringing up its autoconnect profiles
  # (2026-06-25, replaces the old `wireguard-wg0.service` ordering). If wg0 can't
  # come up (no network at boot), sshd won't bind — intended; local console works.
  systemd.services.sshd = {
    after = [ "NetworkManager-wait-online.service" ];
    wants = [ "NetworkManager-wait-online.service" ];
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
