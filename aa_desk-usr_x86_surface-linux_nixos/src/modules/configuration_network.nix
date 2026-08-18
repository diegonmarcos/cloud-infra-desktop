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

  # IPv6 endpoint for the same hub — the literal must be bracketed, because
  # wg's Endpoint= parses host:port and a bare v6 address is all colons.
  # Empty string when host_v6 is absent, which is what every OTHER host's JSON
  # still looks like; the dispatcher below treats "" as "no v6 endpoint".
  wgPublicPrimaryV6 =
    if (wgPublicData.hub ? host_v6) && wgPublicData.hub.host_v6 != ""
    then "[${wgPublicData.hub.host_v6}]:${toString wgPublicData.hub.primary.port}"
    else "";

  # ── Tunnel mode: split vs full (data-driven, per interface) ────────────────
  # `tunnel_mode` in each endpoints JSON is the ONLY place to flip this. Split
  # (default) routes just the mesh subnets into the tunnel; full routes
  # everything (0.0.0.0/0 + ::/0) so all traffic exits via the hub.
  #
  # It has to drive THREE things that must agree, or the tunnel half-works:
  #   1. the peer's allowed-ips     — what wg will encrypt (crypto-routing)
  #   2. ipv4/ipv6.never-default    — whether NM installs a default route via wg
  #   3. the dispatcher script's `wg set … allowed-ips`, which re-applies (1) on
  #      every link-up and would otherwise stomp it straight back to split
  # Set only (1) and packets are encryptable but route nowhere; set only (2) and
  # they route into the tunnel and die with "Required key not available".
  # BOTH variants are always generated as separate NM profiles on the SAME
  # interface (wg0 / wg0-full), so the toggle is live — `nmcli con up wg0-full`
  # or a click in plasma-nm — instead of a JSON edit + 2h closure rebuild.
  # tunnel_mode then only decides which of the two autoconnects at boot.
  mkTunnel = mode: data: rec {
    isFull       = mode == "full";
    allowed4     = if isFull then "0.0.0.0/0" else data.subnet;
    allowed6     = if isFull then "::/0" else data.subnet_v6;
    allowedBoth  = "${allowed4},${allowed6}";
    neverDefault = if isFull then "false" else "true";
  };
  wgTunnel           = mkTunnel "split" wgData;
  wgTunnelFull       = mkTunnel "full"  wgData;
  wgPublicTunnel     = mkTunnel "split" wgPublicData;
  wgPublicTunnelFull = mkTunnel "full"  wgPublicData;

  # Declared boot default per interface — "split" (default) or "full".
  wgBootFull       = (wgData.tunnel_mode or "split") == "full";
  wgPublicBootFull = (wgPublicData.tunnel_mode or "split") == "full";

  # `wg-tunnel {status|json|split|full|toggle} [wg0|wg-public]` — the live
  # toggle. Activating the sibling profile on the same interface swaps routing
  # in place; no rebuild. `json` is the machine-readable form the my-konsole
  # systray consumes.
  wg-tunnel = pkgs.writeShellApplication {
    name = "wg-tunnel";
    runtimeInputs = with pkgs; [ networkmanager wireguard-tools iproute2 gawk coreutils ];
    text = ''
      IFACES="${wgData.client.interface} ${wgPublicData.client.interface}"

      # Active NM profile id bound to an interface ("" when the iface is down).
      active_id() {
        nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
          | awk -F: -v d="$1" '$2 == d { print $1; exit }'
      }
      # split | full | down
      mode_of() {
        case "$(active_id "$1")" in
          *-full) echo full ;;
          "")     echo down ;;
          *)      echo split ;;
        esac
      }
      handshake_of() {
        wg show "$1" latest-handshakes 2>/dev/null | awk '{print $2; exit}' || echo 0
      }
      allowed_of() {
        wg show "$1" allowed-ips 2>/dev/null | awk '{$1=""; sub(/^ /,""); print; exit}'
      }
      endpoint_of() {
        wg show "$1" endpoints 2>/dev/null | awk '{print $2; exit}'
      }
      addr_of() {
        ip -brief addr show "$1" 2>/dev/null | awk '{$1="";$2="";sub(/^  /,""); print}'
      }

      set_mode() {   # $1 = iface, $2 = split|full
        target="$1"; [ "$2" = "full" ] && target="$1-full"
        # Only one interface may hold the default route: drop the other one out
        # of full first, or the two default routes fight and one blackholes.
        if [ "$2" = "full" ]; then
          for other in $IFACES; do
            [ "$other" = "$1" ] && continue
            if [ "$(mode_of "$other")" = "full" ]; then
              echo "wg-tunnel: $other was full — returning it to split first" >&2
              nmcli connection up "$other" >/dev/null || true
            fi
          done
        fi
        nmcli connection up "$target"
      }

      json_one() {
        printf '{"iface":"%s","mode":"%s","allowed_ips":"%s","endpoint":"%s","addresses":"%s","latest_handshake":%s,"profile":"%s"}' \
          "$1" "$(mode_of "$1")" "$(allowed_of "$1")" "$(endpoint_of "$1")" \
          "$(addr_of "$1")" "$(handshake_of "$1")" "$(active_id "$1")"
      }

      cmd="''${1:-status}"; iface="''${2:-}"

      case "$cmd" in
        status)
          for i in $IFACES; do
            printf '%-12s %-6s %s\n' "$i" "$(mode_of "$i")" "$(allowed_of "$i")"
          done
          ;;
        json)
          printf '['
          first=1
          for i in $IFACES; do
            [ "$first" = 1 ] || printf ','
            first=0
            json_one "$i"
          done
          printf ']\n'
          ;;
        split|full)
          [ -n "$iface" ] || { echo "wg-tunnel: $cmd needs an interface ($IFACES)" >&2; exit 2; }
          set_mode "$iface" "$cmd"
          ;;
        toggle)
          [ -n "$iface" ] || { echo "wg-tunnel: toggle needs an interface ($IFACES)" >&2; exit 2; }
          if [ "$(mode_of "$iface")" = "full" ]; then set_mode "$iface" split; else set_mode "$iface" full; fi
          ;;
        *)
          echo "usage: wg-tunnel {status|json|split|full|toggle} [$IFACES]" >&2
          exit 2
          ;;
      esac
    '';
  };

  # Full tunnel is IPv4-only in practice (2026-08-11): neither hub has a global
  # IPv6 address (gcp-proxy's ens4 is v4-only with no v6 default route), so
  # NAT66 for ::/0 has nothing to translate to. The ::/0 half is still declared
  # so the profile is correct the day a hub gains v6 egress; until then v6
  # traffic under a full tunnel goes nowhere. Mesh v6 (fd0c:1d0x::/64) is
  # unaffected — it never leaves the tunnel.

  # Profile builders. Split and full differ ONLY in allowed-ips + never-default;
  # same key, same address, same peer, same interface — so switching profiles is
  # a routing change, not a new tunnel.
  mkWg0Profile = { id, tunnel, autoconnect }: {
    connection = {
      inherit id autoconnect;
      type = "wireguard";
      interface-name = wgData.client.interface;
    };
    wireguard.private-key = "$WG0_PRIVATE_KEY";
    # MTU from JSON, not 1420. A wg frame nested inside a CLAT path (route mtu
    # 1260) is dropped with DF set, and ICMP is filtered there so PMTU discovery
    # never learns it — a black hole that passes small packets and hangs on the
    # first big one. See wireguard-endpoints.json._mtu_doc.
    wireguard.mtu = toString wgData.mtu;
    # allowed-ips carries ONLY the v4 half (2026-07-30): NM's keyfile parser
    # can't handle a combined v4+v6 value here (see the dispatcherScripts
    # workaround below) — the v6 half is added to the kernel peer at runtime
    # by the dispatcher, which keys off CONNECTION_ID to pick the matching half.
    "wireguard-peer.${wgData.hub.wg_public_key}" = {
      endpoint = wgPrimary;
      allowed-ips = tunnel.allowed4;
      persistent-keepalive = toString wgData.persistent_keepalive;
    };
    ipv4 = {
      method = "manual";
      address1 = "${wgData.client.wg_ip}/24";
      dns = wgData.hub.wg_ip;        # Hickory mesh DNS for diegonmarcos.com
      dns-priority = "50";
      # Routing domains (data-driven, from wireguard-endpoints.json.dns_search):
      # systemd-resolved routes ONLY these zones to Hickory (10.0.0.1) — the
      # zones Hickory actually serves (diegonmarcos.com + the internal .app/.db
      # mesh names). All other queries continue to the global DNS (127.0.0.1 =
      # dnscrypt-proxy2). Without this, dns-priority=50 would make Hickory the
      # global primary, but Hickory only knows its declared zones.
      # dns_search is a JSON array; NM's keyfile ipv4.dns-search is a
      # ';'-separated list. Joining with spaces made NM store all three as ONE
      # bogus domain, so diegonmarcos.com never routed to Hickory (403 on mcp.*).
      dns-search = lib.concatStringsSep ";" wgData.dns_search;
      never-default = tunnel.neverDefault;
    };
    # Dual-stack (2026-07-26): cloud wg0 mesh is dual-stack (fd0c:1d00::/64, see
    # wireguard-endpoints.json._ipv6_doc). Mirrors the ipv4 block: manual address
    # from JSON, v6 Hickory alongside v4 Hickory so mesh split-DNS keeps
    # resolving diegonmarcos.com over either stack.
    ipv6 = {
      method = "manual";
      # MANDATORY ON WIREGUARD — NOT a preference. NM's default here is
      # `default-or-eui64`, and eui64 derives the IPv6 interface identifier from
      # the device MAC. A WireGuard interface HAS NO MAC, so NM cannot build a
      # link-local address and logs, every 10s, forever:
      #   device (wg0): linklocal6: failed to get interface identifier;
      #   IPv6 cannot continue
      # The IPv6 stage then never completes, and because it never completes NM
      # never commits the link's finished IP configuration to systemd-resolved —
      # so ipv6.dns AND, critically, dns-search below are silently DROPPED.
      #
      # DIAGNOSED 2026-08-12 from a /mcp failure reporting "HTTP 403 — check
      # that the token is valid". The token was fine (valid to 2036, correct
      # aud); 403 was IDENTICAL with and without an Authorization header, which
      # is what proved auth was never involved. Real chain:
      #   eui64 fails -> wg0 IPv6 never completes -> resolved gets only `~app`
      #   instead of `~diegonmarcos.com ~app ~db` -> mcp.diegonmarcos.com
      #   resolves via PUBLIC DNS to 129.151.228.66 instead of Hickory's
      #   10.0.0.1 -> request arrives from a public IP -> the route is declared
      #   `wg_only: true` (cloud/a_solutions/user-ai_cloud-cgc-mcp/build.json,
      #   proxy.primary) -> Caddy rejects it before auth -> 403.
      # Same interface, only this setting changed: wg0 went from NO IPv6 at all
      # (not even link-local) to fd0c:1d00::5/64 + fe80::…, resolved went from
      # `~app` to all three domains, and the MCP endpoint went 403 -> 200.
      #
      # Note wg-public was already working, which is what made the contrast
      # legible: it had generated a link-local and held its domains, so the
      # difference isolated to this one stage rather than to WireGuard broadly.
      #
      # stable-privacy derives the identifier from a stable secret + interface
      # name (RFC7217), needs no MAC, and is deterministic across reboots.
      addr-gen-mode = "stable-privacy";
      address1 = "${wgData.client.wg_ipv6}/64";
      dns = "${wgData.hub.wg_ipv6} ${wgData.hickory_ipv6}";
      dns-priority = "50";
      dns-search = lib.concatStringsSep ";" wgData.dns_search;
      never-default = tunnel.neverDefault;
    };
  };

  mkWgPublicProfile = { id, tunnel, autoconnect }: {
    connection = {
      inherit id autoconnect;
      type = "wireguard";
      interface-name = wgPublicData.client.interface;
    };
    wireguard.private-key = "$WGPUB_PRIVATE_KEY";
    # See wireguard-public-endpoints.json._mtu_doc. This is the tunnel meant to
    # carry IPv4 on a v6-only uplink, so it is always the nested one.
    wireguard.mtu = toString wgPublicData.mtu;
    "wireguard-peer.${wgPublicData.hub.wg_public_key}" = {
      endpoint = wgPublicPrimary;
      allowed-ips = tunnel.allowed4;
      persistent-keepalive = toString wgPublicData.persistent_keepalive;
    };
    ipv4 = {
      method = "manual";
      address1 = "${wgPublicData.client.wg_ip}/24";
      dns-search = "";
      never-default = tunnel.neverDefault;
    };
    # Dual-stack (2026-07-26): wg-public mesh is dual-stack too
    # (fd0c:1d01::/64, see wireguard-public-endpoints.json._ipv6_doc).
    ipv6 = {
      method = "manual";
      # Set explicitly for the same reason as wg0 — see the long note there.
      # This interface happened to come up with a working link-local, so it did
      # NOT exhibit the bug, but that was luck rather than configuration: the
      # profile carried the identical `default-or-eui64` default that wedged
      # wg0's IPv6 stage. Pinning it here removes the coin flip.
      addr-gen-mode = "stable-privacy";
      address1 = "${wgPublicData.client.wg_ipv6}/64";
      dns-search = "";
      never-default = tunnel.neverDefault;
    };
  };

  # ── NAT64/DNS64/CLAT declarations (data-driven) ─────────────────────────────
  # DNS64 resolver addresses + v6 fallback DNS + the CLAT enable flag.
  # Edit nat64.json, not this file — repo principle 6 (no hardcoded IPs in .nix).
  nat64Data = builtins.fromJSON (builtins.readFile ./nat64.json);

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
  # Two full tunnels means two default routes over two wg devices, and whichever
  # loses the metric tie-break silently blackholes. Catch it at eval, not at 3am
  # on hotel WiFi. (See the tunnel_mode block above.)
  assertions = [
    {
      assertion = !(wgBootFull && wgPublicBootFull);
      message = "wireguard: tunnel_mode = \"full\" is set on BOTH wireguard-endpoints.json (wg0) and wireguard-public-endpoints.json (wg-public), so both -full profiles would autoconnect and fight over the default route. Only one may boot full — set the other back to \"split\" (you can still flip it live with `wg-tunnel full wg-public`).";
    }
  ];

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
    # v6-capable fallback (Cloudflare + Quad9 IPv6 anycast) — replaces the old
    # v4-only [1.1.1.1, 9.9.9.9], which is useless on a v6-only network: resolved
    # could never even reach those addresses. Data-driven from nat64.json.
    fallbackDns = nat64Data.v6_fallback_dns;
    # Ordered global resolvers: dnscrypt-proxy2 first; on its failure resolved
    # rotates to the next, then to the public nat64.net DNS64 resolvers. They
    # synthesize 64:ff9b-style AAAA whose NAT64 gateway is reachable over plain
    # IPv6. This is the escape hatch for an IPv6-only WiFi with NO NAT64 gateway
    # of its own (GitHub etc. is IPv4-only): dnscrypt can't reach its DoH
    # upstreams → SERVFAIL → resolved fails over to nat64.net → the v4-only host
    # becomes reachable via NAT64 over IPv6. On any healthy/dual-stack network
    # 127.0.0.1 answers first, so nat64.net never sees a query (dnscrypt privacy
    # preserved). fallbackDns above is NOT the right slot for this — it only
    # fires when zero DNS= servers exist, which never happens while
    # dnscrypt-proxy2 is listening.
    # Data-driven from nat64.json (repo principle 6 — no hardcoded IPs here).
    # UNTESTED end-to-end on real hardware: only exercisable on a real
    #   IPv6-only-no-NAT64 network. Covered by test-ipv6-only.nix (nixosTest).
    #   Verify nat64.net resolver IPs are current at https://nat64.net before relying.
    extraConfig = ''
      DNS=127.0.0.1 ${lib.concatStringsSep " " nat64Data.public_dns64_fallback_resolvers}
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
      # Split (mesh-only) and full (0.0.0.0/0) live side by side on the SAME
      # interface. Exactly one of each pair is active at a time; `nmcli con up
      # wg0-full` swaps them in place, and both show up in the plasma-nm applet.
      # tunnel_mode in the endpoints JSON picks which one autoconnects at boot.
      "wg0" = mkWg0Profile {
        id = "wg0";
        tunnel = wgTunnel;
        autoconnect = if wgBootFull then "false" else "true";
      };
      "wg0-full" = mkWg0Profile {
        id = "wg0-full";
        tunnel = wgTunnelFull;
        autoconnect = if wgBootFull then "true" else "false";
      };
      "wg-public" = mkWgPublicProfile {
        id = "wg-public";
        tunnel = wgPublicTunnel;
        autoconnect = if wgPublicBootFull then "false" else "true";
      };
      "wg-public-full" = mkWgPublicProfile {
        id = "wg-public-full";
        tunnel = wgPublicTunnelFull;
        autoconnect = if wgPublicBootFull then "true" else "false";
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
      # ~/.config/wireguard/* are home-manager symlinks that ultimately resolve
      # into the VAULT REPO: /home/diego/git/cloud-vault/A0_keys/providers/wireguard/.
      # That path lives on the @nosnap/git subvolume, so this unit cannot read a
      # single key until that mount exists — see RequiresMountsFor below.
      WG0_KEY=/home/diego/.config/wireguard/privatekey
      WGPUB_KEY=/home/diego/.config/wireguard/privatekey-public
      MISSING=""
      [ -r "$WG0_KEY" ]   && printf 'WG0_PRIVATE_KEY=%s\n'   "$(tr -d '\n\r' < "$WG0_KEY")"   >> "$OUT" || MISSING="$MISSING $WG0_KEY"
      [ -r "$WGPUB_KEY" ] && printf 'WGPUB_PRIVATE_KEY=%s\n' "$(tr -d '\n\r' < "$WGPUB_KEY")" >> "$OUT" || MISSING="$MISSING $WGPUB_KEY"
      if [ -n "$MISSING" ]; then
        # Fail LOUDLY and name the files. Previously the last `[ -r ]` test
        # simply returned 1 under `set -e`, so the unit died with a bare
        # "status=1/FAILURE" and no clue — while NetworkManager, handed an empty
        # env file, silently fell back to PROMPTING THE USER for the wg0
        # password (observed 2026-08-11 19:25 after the git subvolume failed to
        # mount at boot, which dangled every key symlink).
        echo "nm-wg-secrets: unreadable key(s):$MISSING" >&2
        echo "nm-wg-secrets: is /home/diego/git mounted? the vault lives there." >&2
        exit 1
      fi
    '';
    # The keys resolve into /home/diego/git/cloud-vault, so this unit MUST NOT run
    # before that subvolume is mounted. Without this, boot ordering decides
    # whether your VPN comes up or NetworkManager asks you to type a password.
    unitConfig.RequiresMountsFor = "/home/diego/git";
  };

  # Runtime endpoint switcher: `wg-fallback {status|primary|fallback}`
  # NOTE: with NM-managed wg0, a `wg set` endpoint tweak survives only until NM
  # reactivates the profile; for a permanent fallback port, edit the profile +
  # rebuild. The `status` subcommand still works as-is for quick inspection.
  environment.systemPackages = [ wg-fallback wg-tunnel ];

  # WORKAROUND (2026-07-30): NetworkManager's keyfile parser (nmcli 1.48.10)
  # silently fails to apply a per-peer `allowed-ips` value that carries BOTH
  # the IPv4 and IPv6 mesh subnet together ("keyfile: ... has invalid
  # allowed-ips" in the journal) — the kernel wg interface is left with
  # allowed-ips=(none), so all traffic (v4 AND v6) dies with "Required key
  # not available", even though NM correctly brought the interface up and
  # assigned both addresses. Reapply AllowedIPs directly to the kernel via
  # `wg set` once NM reports the device up — this bypasses NM's broken
  # keyfile-list parsing for this one property while NM still owns
  # everything else (keys, addresses, DNS, autoconnect).
  networking.networkmanager.dispatcherScripts = [
    {
      source = pkgs.writeShellScript "wg-dualstack-allowedips-fix" ''
        IFACE="$1"; STATUS="$2"
        [ "$STATUS" = "up" ] || exit 0
        # Key off CONNECTION_ID, not IFACE: wg0 and wg0-full share one interface
        # and differ only in allowed-ips, so matching on the interface alone
        # would re-apply the split set over a full profile on every link-up.
        # NM exports CONNECTION_ID to dispatcher scripts.
        case "''${CONNECTION_ID:-$IFACE}" in
          wg0)
            ${pkgs.wireguard-tools}/bin/wg set "$IFACE" peer ${wgData.hub.wg_public_key} \
              allowed-ips "${wgTunnel.allowedBoth}"
            ;;
          wg0-full)
            ${pkgs.wireguard-tools}/bin/wg set "$IFACE" peer ${wgData.hub.wg_public_key} \
              allowed-ips "${wgTunnelFull.allowedBoth}"
            ;;
          wg-public)
            ${pkgs.wireguard-tools}/bin/wg set "$IFACE" peer ${wgPublicData.hub.wg_public_key} \
              allowed-ips "${wgPublicTunnel.allowedBoth}"
            ;;
          wg-public-full)
            ${pkgs.wireguard-tools}/bin/wg set "$IFACE" peer ${wgPublicData.hub.wg_public_key} \
              allowed-ips "${wgPublicTunnelFull.allowedBoth}"
            ;;
        esac
      '';
      type = "basic";
    }

    # CLAT on an IPv6-only uplink (2026-08-11, verified in the field).
    # clatd.service is WantedBy=multi-user.target, so it only ever runs at BOOT
    # — and at boot on a dual-stack network it correctly self-disables and
    # exits. Join an IPv6-only WiFi later and NOTHING re-triggers it.
    #
    # That is fatal rather than degraded: both WG endpoints are raw IPv4
    # literals (hub.host in wireguard{,-public}-endpoints.json), and DNS64 can
    # only synthesize AAAA for NAMES — a literal has nothing to translate. No
    # CLAT ⇒ no route to either hub ⇒ the entire mesh is unreachable on exactly
    # the network the dual-stack work was meant to survive.
    #
    # Restart clatd on link-up when there is no IPv4 default route. When native
    # IPv4 exists we skip it entirely: clatd would self-disable anyway, and
    # churning the unit on every link event is noise.
    {
      source = pkgs.writeShellScript "clat-on-v6only" ''
        IFACE="$1"; STATUS="$2"
        # dhcp4-change matters as much as up: on a dual-stack link NM can fire
        # `up` BEFORE DHCPv4 has finished, and the v4 lease lands afterwards.
        case "$STATUS" in up|dhcp4-change|dhcp6-change) ;; *) exit 0 ;; esac
        # Never recurse on our own tunnels: wg0 coming up must not re-run this.
        #
        # VIRTUAL BRIDGES MUST BE IGNORED TOO (2026-08-12). docker0 carries a
        # private IPv4 (172.16.0.1), so an `up` event on it sets NATIVE4=1 below
        # and the native-IPv4 branch then runs `systemctl stop clatd` — killing
        # IPv4 on a genuinely IPv6-only uplink because an unrelated bridge
        # appeared. Not hypothetical: this dispatcher was observed running with
        # IFACE=docker0 (its resolvectl remedy pinned the DNS64 servers to
        # docker0, a link with no default route). Only a real uplink can answer
        # "does this machine have native IPv4".
        case "$IFACE" in
          ${wgData.client.interface}|${wgPublicData.client.interface}|lo|clat) exit 0 ;;
          docker*|br-*|virbr*|veth*|waydroid*|tun*|tap*) exit 0 ;;
        esac

        OVR=/run/systemd/system/clatd.service.d/plat-prefix.conf
        # Drop any forced prefix FIRST, on every path. It belongs to whichever
        # network we were last on; leaving it behind (the native-v4 branch used
        # to exit before this) means the next IPv6-only network can start clatd
        # against the wrong NAT64 prefix.
        ${pkgs.coreutils}/bin/rm -f "$OVR"

        # Does this link have NATIVE IPv4? Ask NM, not the route table.
        # At `up` time DHCPv4 may not have installed the route yet, so an empty
        # table reads as "IPv6-only" — that race is how an earlier version of
        # this script started CLAT on a dual-stack network and left a competing
        # `default dev clat` route behind, killing IPv4 when the native route
        # arrived seconds later. NM's own IP4_NUM_ADDRESSES describes the
        # connection being activated and is authoritative; only fall back to the
        # route table when NM told us nothing (e.g. a manual invocation).
        if [ -n "''${IP4_NUM_ADDRESSES:-}" ]; then
          if [ "''${IP4_NUM_ADDRESSES}" -gt 0 ] 2>/dev/null; then NATIVE4=1; else NATIVE4=0; fi
        elif ${pkgs.iproute2}/bin/ip -4 route show default \
               | ${pkgs.gnugrep}/bin/grep -qv ' dev clat'; then
          NATIVE4=1
        else
          NATIVE4=0
        fi

        # ── wg-public endpoint follows the uplink's address family ─────────────
        # The NM profile pins the IPv4 endpoint, which cannot establish at all on
        # an IPv6-only network: 2026-08-11, on a v6-only WiFi with no NAT64, both
        # tunnels sat 55 MINUTES stale because their endpoints are IPv4 literals
        # with nothing to translate them. The hub has been reachable over IPv6 the
        # whole time (udp/51821 open to ::/0 in c_vps/vps_oci security_rules);
        # nothing knew the address until the terraform output was added.
        #
        # Switching the live peer beats re-writing the NM profile: `wg set` takes
        # effect immediately with no connection bounce, and the profile stays the
        # v4 default so a fresh boot on a normal network is unchanged.
        #
        # Empty WGPUB_EP_V6 (no host_v6 in the JSON) makes both arms no-ops, so a
        # host whose endpoints file has not been updated behaves exactly as before.
        WGPUB_IF="${wgPublicData.client.interface}"
        WGPUB_PUB="${wgPublicData.hub.wg_public_key}"
        WGPUB_EP_V4="${wgPublicPrimary}"
        WGPUB_EP_V6="${wgPublicPrimaryV6}"
        wgpub_endpoint() { # $1 = endpoint
          [ -n "$1" ] || return 0
          ${pkgs.iproute2}/bin/ip link show "$WGPUB_IF" >/dev/null 2>&1 || return 0
          ${pkgs.wireguard-tools}/bin/wg set "$WGPUB_IF" peer "$WGPUB_PUB" endpoint "$1" 2>/dev/null \
            && ${pkgs.util-linux}/bin/logger -t clat-on-v6only "wg-public endpoint -> $1"
        }

        if [ "$NATIVE4" = 1 ]; then
          # Native IPv4 present ⇒ tear down any CLAT left from a previous
          # IPv6-only network. clatd's tun device is PERSISTENT and its default
          # route outlives a reconnect; it only loses to the native route on
          # metric, so leaving it running blackholes IPv4 the moment that route
          # flaps — which is exactly what roaming does.
          ${config.systemd.package}/bin/systemctl daemon-reload
          ${config.systemd.package}/bin/systemctl stop clatd 2>/dev/null || true
          # Back to the v4 endpoint: a v6 endpoint left over from the previous
          # network is not automatically better here, and on an IPv4-only uplink
          # it is unreachable.
          wgpub_endpoint "$WGPUB_EP_V4"
          exit 0
        fi

        # IPv6-only uplink: point wg-public at its IPv6 endpoint FIRST, before any
        # CLAT work below. If this handshakes, the tunnel carries IPv4 itself and
        # the whole NAT64 ladder becomes a fallback rather than the only path.
        wgpub_endpoint "$WGPUB_EP_V6"

        # IPv6-only from here. clatd finds the NAT64 prefix by RFC7050 — it asks
        # for AAAA on ipv4only.arpa and reads the prefix out of the synthesized
        # answer — so it needs a DNS64 resolver. Observed 2026-08-11 on a real
        # v6-only WiFi: this script fired correctly and clatd still died with
        # "No PLAT prefix could be discovered."
        #
        # Prefer a LOCAL NAT64 at the RFC6052 well-known prefix before touching
        # DNS: many v6-only networks run NAT64 at 64:ff9b::/96 while publishing
        # no DNS64 at all. Probing it keeps every IPv4 packet (both WG tunnels
        # included) on the local gateway instead of hairpinning through
        # nat64.net's volunteer service, which nat64.json itself flags as
        # unverified. clatd's own conf is empty, so forcing plat-prefix via a
        # /run drop-in (tmpfs — gone on reboot) skips discovery entirely.
        # force <clatd-args> — pin clatd's argv via the /run drop-in, skipping
        # whichever discovery step we have already decided cannot work.
        force() {
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$OVR")"
          ${pkgs.coreutils}/bin/printf '[Service]\nExecStart=\nExecStart=%s/bin/clatd %s\n' \
            ${config.services.clatd.package} "$1" > "$OVR"
        }

        # TIER 1 — a NAT64 on THIS network at the RFC6052 well-known prefix.
        # Always preferred: every IPv4 packet stays on the local gateway.
        if ${pkgs.iputils}/bin/ping -6 -c1 -W2 ${nat64Data.nat64_probe_target} >/dev/null 2>&1; then
          force 'plat-prefix=${nat64Data.nat64_wellknown_prefix}'

        # TIER 2 — the system resolver really is a DNS64: let clatd discover the
        # LOCAL prefix by RFC7050, as upstream intends.
        #
        # `timeout 5` is load-bearing. This query used to run unbounded, and on
        # 2026-08-12 it hit dnscrypt-proxy2 (127.0.0.1, first in resolved's DNS=
        # list) whose upstreams are IPv4 literals — unreachable on a v6-only
        # link, so it TIMED OUT rather than SERVFAILing. Inside an NM dispatcher
        # script that stalls the whole event, and resolved never rotates to the
        # DNS64 servers because it never saw a failure.
        elif ${pkgs.coreutils}/bin/timeout 5 ${config.systemd.package}/bin/resolvectl \
               query --type=AAAA --legend=no ipv4only.arpa >/dev/null 2>&1; then
          : # discovery will work unaided${lib.optionalString (nat64Data.clat_plat_prefix != null) ''

        # TIER 3a — the fleet's OWN NAT64. Self-hosted: no volunteer service in
        # the path. Set nat64.json#clat_plat_prefix to enable.
        else
          force 'plat-prefix=${toString nat64Data.clat_plat_prefix}'
        ''}${lib.optionalString (nat64Data.clat_plat_prefix == null && (nat64Data.clat_dns64_direct or false)) ''

        # TIER 3b — public DNS64, queried DIRECTLY by clatd (its own Net::DNS
        # resolver), bypassing resolved/dnscrypt/per-link DNS. Off by default;
        # see nat64.json#clat_dns64_direct for the privacy cost.
        else
          ${pkgs.util-linux}/bin/logger -t clat-on-v6only -p daemon.warning \
            "LAST RESORT: no local NAT64, no local DNS64. clatd will query ${lib.concatStringsSep "," nat64Data.public_dns64_fallback_resolvers} directly and adopt its prefix — ALL plain IPv4 will transit a third-party volunteer NAT64 (nat64.json#clat_dns64_direct)."
          force 'dns64-servers=${lib.concatStringsSep "," nat64Data.public_dns64_fallback_resolvers}'
        ''}${lib.optionalString (nat64Data.clat_plat_prefix == null && !(nat64Data.clat_dns64_direct or false)) ''

        # FAIL CLOSED — no local NAT64, no local DNS64, no self-hosted prefix,
        # and third-party transit is disabled. Say so instead of leaving clatd to
        # die with a message that blames DNS.
        else
          ${pkgs.util-linux}/bin/logger -t clat-on-v6only -p daemon.warning \
            "IPv6-only uplink with no NAT64 and no DNS64. No IPv4 will be available: clat_plat_prefix is unset and clat_dns64_direct is false (fail-closed by design). Set one in nat64.json, or use a wg hub with tunnel_mode=full."
        ''}
        fi
        ${config.systemd.package}/bin/systemctl daemon-reload
        ${config.systemd.package}/bin/systemctl restart clatd
      '';
      type = "basic";
    }
  ];

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

  # ═══════════════════════════════════════════════════════════════════════════
  # CLAT (464XLAT) — reach raw IPv4 literals over an IPv6-only uplink
  # ═══════════════════════════════════════════════════════════════════════════
  # DNS64 (services.resolved above) only helps hostnames that get resolved
  # through the synthesizing resolver. Anything that skips DNS and connects to
  # a raw IPv4 literal — e.g. wireguard-endpoints.json hub.host = 35.226.147.64 —
  # has nothing to translate its packets for it. clatd fills that gap: it
  # self-discovers the NAT64 prefix via RFC7050 (ipv4only.arpa) and hands out a
  # local "clat" interface that NATs IPv4 traffic into synthesized IPv6, so
  # even literal-IP connections work on a v6-only network.
  #
  # services.clatd exists as a NixOS module at the pinned nixos-24.11
  # (nixos/modules/services/networking/clatd.nix, package clatd ~1.6) — used
  # directly rather than hand-rolling a systemd unit.
  #
  # clatd auto-disables when native IPv4 is already present, so it's safe to
  # enable unconditionally: it's a no-op on every network this laptop uses
  # today and only activates on a genuinely v6-only uplink. No NAT64 prefix is
  # hardcoded — it's discovered live per-network. Gated by nat64.json's
  # clat_enable flag (data-driven, repo principle 6) rather than a bare `true`.
  services.clatd.enable = nat64Data.clat_enable;

  # NO `services.clatd.enableNetworkManagerIntegration` HERE — it does not exist
  # in this nixpkgs, and setting it fails the build outright:
  #     error: The option `services.clatd.enableNetworkManagerIntegration'
  #            does not exist.  (CI run 31590064922, 2026-08-12)
  #
  # Newer nixpkgs (26.11) grew that option plus a dispatcher of its own whose
  # whole body is an unconditional `systemctl restart clatd` — which WOULD race
  # the clat-on-v6only script above and could restart clatd before its
  # plat-prefix drop-in is written. The 24.11 module pinned here has neither the
  # option nor any dispatcherScripts, so clat-on-v6only is the only dispatcher
  # and there is nothing to disable.
  #
  # Re-add the disable ONLY if this host is bumped past 24.11 — at which point
  # the race becomes real. Verify with:
  #   grep -c dispatcherScripts <nixpkgs>/nixos/modules/services/networking/clatd.nix
}
