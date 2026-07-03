# modules/net/gateway/sing-box-tproxy.nix — Thin shim: wires osf.gateway.edge.tproxy
# options into the osf.sing-box-gateway module (osfiles-modules).
#
# All sing-box service logic (TUN, config generation, secret injection, DNS
# fallback, iptables TPROXY) lives in osfiles-modules. This file only maps
# the gateway-specific options + the gateway-cd outbound group.
#
# Gated on: cfg.enable && ecfg.enable && ecfg.tproxy.enable
{
  config,
  lib,
  osfLib,
  ...
}:
let
  wk = osfLib.wellKnown;
  inherit (osfLib) mesh;
  nets = osfLib.networks;

  cfg = config.osf.gateway;
  ecfg = cfg.edge;
  tp = ecfg.tproxy;
  stls = osfLib.singBoxUpstreams.shadowtls;

  sorCfg = ecfg.sorClient;

  # ── Gateway-cd outbound group (always present for edge gateways) ──
  gatewayCdGroup = {
    outbounds = [
      {
        # Route A — Rust tcp-over-redis: dials the local Rust client listener,
        # which bridges to Redis. Terminates at cd :26200 (sing-box-mux).
        type = "shadowsocks";
        tag = "to-core-rs";
        server = wk.localhost;
        server_port = ecfg.tunnelPort;
        method = "2022-blake3-aes-256-gcm";
        password = ecfg.muxPassword;
        multiplex = {
          enabled = true;
          protocol = "smux";
          padding = true;
          max_connections = 4;
          min_streams = 2;
        };
      }
    ]
    # Route B — isolated SoR client: loopback socks5 to the separate
    # sing-box-sor process. Crash-isolated from the main tproxy.
    ++ lib.optionals sorCfg.enable [
      {
        type = "socks";
        tag = "to-core-sor";
        server = wk.localhost;
        server_port = sorCfg.listenPort;
      }
    ];
  };

  clashOn = tp.clashApiPort != null;

in
lib.mkIf (cfg.enable && ecfg.enable && tp.enable) {
  osf.sing-box-gateway = {
    enable = true;

    shadowtlsDefaults = {
      inherit (stls)
        version
        sni
        ssMethod
        ssPassword
        password
        ;
    };

    outboundGroups = {
      gateway-cd = gatewayCdGroup;
    }
    // tp.outboundGroups;
    extraOutbounds = tp.outbounds;

    tunAddresses = [
      nets.lax-2.singBoxTunAddr
      "fdfe:dcba:9876::1/126"
    ];
    routeExcludeAddresses = [
      "${wk.dns.alidns}/32"
      "${wk.easytier.magicDnsRelay}/32"
    ];

    extraGeneratorArgs = {
      route_direct_cidrs = [
        mesh.meshSubnet
        nets.cosceneMesh.cidr
        nets.k8s.svcCidr
        nets.k8s.podCidr
        wk.cgnat
      ];
      find_process = true;
      # route_direct_domains: use generator defaults (.lockin.mesh, .et.net, .ts.net)
    };

    extraRouteRules = tp.routeRules ++ [
      {
        domain_suffix = [ ".lockin.mesh" ];
        action = "route";
        outbound = "direct";
      }
      {
        domain_suffix = [ ".${cfg.tailnetName}" ];
        action = "route";
        outbound = "direct";
      }
    ];

    dns = {
      domestic = {
        type = "udp";
        tag = "dns-domestic";
        server = wk.dns.alidns;
      };
      foreign = {
        type = "https";
        tag = "dns-foreign";
        server = wk.dns.cloudflare;
        path = "/dns-query";
      };
      detour = tp.finalOutbound;
      extraServers = tp.dnsServers;
      extraRules = tp.dnsRules;
    };

    inherit (tp) finalOutbound;
    inherit (tp) sourceSubnets;

    clashApi = lib.mkIf clashOn {
      enable = true;
      port = tp.clashApiPort;
      host = tp.clashApiHost;
      secretFile = config.sops.secrets.clash-api-secret.path;
    };

    afterServices = [
      "network-online.target"
      "easytier.service"
    ]
    ++ lib.optional sorCfg.enable "${sorCfg.systemdName}.service";

    conflictServices = [ "sing-box-tun-slv.service" ];

    configPostProcess =
      c:
      c
      // {
        experimental = c.experimental // {
          cache_file = c.experimental.cache_file // {
            store_dns = true;
          };
        };
      };
  };
}
