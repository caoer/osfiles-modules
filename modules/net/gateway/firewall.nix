# modules/net/gateway/firewall.nix — Layered nftables firewall for gateway roles.
#
# Base (cfg.enable):  nftables ACLs for mesh services, BBR tuning
# Edge (cfg.edge):    Black-hole direct ET to core router public IP (OUTPUT chain)
# Core:               Port opened via meshServices (tier=trusted)
#
# Tier semantics (from mesh-services.nix):
#   trusted  — mesh subnets only
#   both     — mesh + LAN subnets (DNS, AdGuard UI, proxy inbounds)
#   internal — no firewall rules (localhost-bound)
#
# NAT activates when natInternalInterface + natExternalInterface are set.
{
  config,
  lib,
  osfLib,
  ...
}:
let
  inherit (osfLib) mesh;
  nets = osfLib.networks;

  cfg = config.osf.gateway;
  hasNat = cfg.natInternalInterface != null && cfg.natExternalInterface != null;

  meshSubnets = [
    mesh.meshSubnet
    nets.vpnPortalCidr
  ];
  allInternalSubnets = meshSubnets ++ cfg.lanSubnets;

  allServices = lib.attrValues cfg.meshServices;

  # Collect ports by tier
  portsForTier =
    tier: proto: map (s: s.port) (lib.filter (s: s.proto == proto && s.tier == tier) allServices);

  trustedTcpPorts = portsForTier "trusted" "tcp";
  trustedUdpPorts = portsForTier "trusted" "udp";
  bothTcpPorts = portsForTier "both" "tcp";
  bothUdpPorts = portsForTier "both" "udp";

  # Format helpers for nft syntax
  fmtSet = items: builtins.concatStringsSep ", " items;
  fmtPorts = ports: builtins.concatStringsSep ", " (map toString ports);

  # Generate nft ACL rule — only when ports list is non-empty
  mkNftAcl =
    subnets: proto: ports:
    lib.optionalString (ports != [ ]) ''
      ip saddr { ${fmtSet subnets} } ${proto} dport { ${fmtPorts ports} } accept
    '';
in
lib.mkMerge [
  # ── Base: shared gateway firewall (gated on cfg.enable) ──────────
  (lib.mkIf (cfg.enable && !config.osf.network.enable) {
    networking.nftables.enable = true;

    osf.netTuning.preset = lib.mkDefault "basic";

    networking.firewall = {
      # EasyTier ports are public (mesh discovery needs them reachable from anywhere)
      allowedTCPPorts = [
        11010 # EasyTier TCP
        11011 # EasyTier WS/WG
        11012 # EasyTier WSS
      ];
      allowedUDPPorts = [
        11010 # EasyTier UDP
        11011 # EasyTier WG
      ];

      extraInputRules = ''
        # Trusted tier: mesh subnets only
        ${mkNftAcl meshSubnets "tcp" trustedTcpPorts}
        ${mkNftAcl meshSubnets "udp" trustedUdpPorts}
        # Both tier: mesh + LAN subnets
        ${mkNftAcl allInternalSubnets "tcp" bothTcpPorts}
        ${mkNftAcl allInternalSubnets "udp" bothUdpPorts}
        # Accept tproxy-marked packets
        meta mark & 0x1 == 0x1 accept
      '';
    };
  })

  # ── NAT: only when interfaces are specified ──────────────────────
  (lib.mkIf (cfg.enable && !config.osf.network.enable && hasNat) {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.ipv6.conf.${cfg.natExternalInterface}.accept_ra" = 2;
    };

    networking.nat = {
      enable = true;
      internalInterfaces = [ cfg.natInternalInterface ];
      externalInterface = cfg.natExternalInterface;
    };
  })

  # ── Edge: black-hole direct ET to core router (OUTPUT chain) ────
  (lib.mkIf
    (cfg.enable && !config.osf.network.enable && cfg.edge.enable && cfg.edge.coreRouterPublicIp != null)
    {
      networking.nftables.tables.gateway-edge-blackhole = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority 0; policy accept;
            ip daddr ${cfg.edge.coreRouterPublicIp} tcp dport 11010 drop comment "force ET through mux tunnel"
            ip daddr ${cfg.edge.coreRouterPublicIp} udp dport 11010 drop comment "force ET through mux tunnel"
          }
        '';
      };
    }
  )
]
