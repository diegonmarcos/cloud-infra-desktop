# test-ipv6-only.nix — pkgs.nixosTest proving the IPv6-only-WiFi + NAT64/CLAT
# escape hatch (PART B of the 2026-07-26 dual-stack work) actually functions.
#
# Per FIRE RULE 5: every solution needs a tester. This exercises the scenario
# configuration_network.nix's DNS64 fallbackDns/extraConfig + services.clatd
# are built for: a guest network whose uplink offers ONLY IPv6 plus a DNS64
# resolver — no native IPv4 at all.
#
# Not wired into the real host config (data-driven from wireguard*.json/
# nat64.json which assume the Surface's actual identity) — this is a
# self-contained topology of its own: a "router" node running Tayga (NAT64)
# + a DNS64-capable resolver + a v4-only "website" node, and a "client" node
# that mirrors configuration_network.nix's resolved+clatd stanza but with its
# uplink forced to v6-only (no DHCP, SLAAC only, no IPv4 configured at all).
#
# Run via: nix build .#checks.x86_64-linux.test-ipv6-only   (or `build.sh check`)
{ pkgs, lib, ... }:

let
  nat64Data = builtins.fromJSON (builtins.readFile ./nat64.json);
  # NAT64 well-known prefix (RFC 6052) — Tayga defaults to this if unconfigured.
  plat = "64:ff9b::/96";
in
pkgs.nixosTest {
  name = "ipv6-only-nat64-clat";

  nodes = {
    # ── router: SLAAC + RA(PREF64) + NAT64 (Tayga) + DNS64 (unbound) ─────────
    router = { config, pkgs, ... }: {
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = [{ address = "192.168.1.1"; prefixLength = 24; }];
      networking.interfaces.eth2.ipv6.addresses = [{ address = "fd00:dead:beef::1"; prefixLength = 64; }];
      networking.nat = {
        enable = true;
        internalIPs = [ "192.168.1.0/24" ];
        externalInterface = "eth1";
      };
      # Router advertisements: SLAAC only, no DHCPv6, so the client autoconfigures
      # purely from RA on the v6-only side (eth2).
      services.radvd = {
        enable = true;
        config = ''
          interface eth2 {
            AdvSendAdvert on;
            AdvManagedFlag off;
            AdvOtherConfigFlag off;
            prefix fd00:dead:beef::/64 { };
          };
        '';
      };
      services.tayga = {
        enable = true;
        ipv4.pool = "192.168.255.0/24";
        ipv6Addr = "fd00:dead:beef::1";
        ipv4Addr = "192.168.1.1";
        mapping = { };
      };
      services.unbound = {
        enable = true;
        settings.server = {
          interface = [ "fd00:dead:beef::1" ];
          access-control = [ "fd00:dead:beef::/64 allow" ];
          module-config = "\"dns64 validator iterator\"";
          dns64-prefix = plat;
        };
      };
      networking.firewall.enable = false;
    };

    # ── website: the v4-only site the client needs to reach ──────────────────
    website = { ... }: {
      networking.interfaces.eth1.ipv4.addresses = [{ address = "192.168.1.2"; prefixLength = 24; }];
      networking.defaultGateway = { address = "192.168.1.1"; interface = "eth1"; };
      networking.firewall.enable = false;
      services.nginx = {
        enable = true;
        virtualHosts."v4only.example".locations."/".return = "200 'v4-only-ok'";
      };
    };

    # ── client: mirrors configuration_network.nix's DNS64+CLAT stanza ────────
    client = { config, pkgs, ... }: {
      networking.useDHCP = false;
      networking.interfaces.eth2.useDHCP = false;
      # No IPv4 configured anywhere — genuinely v6-only uplink; SLAAC handles
      # the address from the router's RA.
      networking.hosts = { }; # keep DNS honest — no /etc/hosts shortcuts

      services.resolved = {
        enable = true;
        dnssec = "false";
        fallbackDns = nat64Data.v6_fallback_dns;
        extraConfig = ''
          DNS=fd00:dead:beef::1
        '';
      };
      networking.networkmanager.enable = false; # keep test topology simple

      services.clatd.enable = true;
    };
  };

  testScript = ''
    start_all()
    router.wait_for_unit("radvd.service")
    router.wait_for_unit("tayga.service")
    router.wait_for_unit("unbound.service")
    website.wait_for_unit("nginx.service")

    client.wait_for_unit("systemd-networkd.service")
    client.wait_for_unit("systemd-resolved.service")

    # (1) host acquires a SLAAC address on the v6-only uplink
    client.wait_until_succeeds(
        "ip -6 addr show eth2 scope global | grep -q 'fd00:dead:beef:'"
    )

    # (2) resolvectl synthesizes a DNS64 AAAA for the v4-only hostname, inside
    # the NAT64 prefix (64:ff9b::/96)
    client.wait_until_succeeds(
        "resolvectl query v4only.example --type=AAAA | grep -q '64:ff9b::'"
    )

    # (3) clatd brings up its translating interface and self-discovers NAT64
    client.wait_for_unit("clatd.service")
    client.wait_until_succeeds("ip link show clat | grep -q 'clat'")

    # (4) a raw IPv4-literal connection succeeds via the clat interface
    client.succeed("curl -s -o /dev/null -w '%{http_code}' http://192.168.1.2/ | grep -q 200")

    # (5) an HTTPS-shaped fetch by hostname (DNS64-resolved) returns 200
    client.succeed(
        "curl -s -o /dev/null -w '%{http_code}' http://v4only.example/ | grep -q 200"
    )
  '';
}
