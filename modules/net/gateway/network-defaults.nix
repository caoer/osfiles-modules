# modules/net/gateway/network-defaults.nix — Zone + service defaults for gateways.
#
# Replaces firewall.nix (ACL generation) and mesh-services.nix (service registry).
# Enables osf.network, sets zones from the injected mesh registry, registers
# services by role.
{
  config,
  lib,
  osfLib,
  ...
}:
let
  cfg = config.osf.gateway;
  inherit (osfLib) mesh;
in
lib.mkMerge [
  # ── Base: all gateways ──────────────────────────────────────────
  (lib.mkIf cfg.enable {
    osf.network = {
      enable = true;
      zones.mesh = lib.mkDefault mesh.meshCidrs;

      services = {
        ssh = {
          port = 22;
          proto = "tcp";
          allow = [ "mesh" ];
          desc = "SSH";
        };
        adguard-ui = {
          port = 3000;
          proto = "tcp";
          allow = [
            "mesh"
            "lan"
          ];
          desc = "AdGuard Home UI";
        };
        dns = {
          port = 53;
          proto = "both";
          allow = [
            "mesh"
            "lan"
          ];
          desc = "AdGuard DNS";
        };
        # mosdns/easytier-rpc: internal (allow=[] -> no rule, loopback only)
        mosdns = {
          port = 5353;
          proto = "both";
          allow = [ ];
          desc = "MosDNS";
        };
        easytier-rpc = {
          port = 15888;
          proto = "tcp";
          allow = [ ];
          desc = "EasyTier RPC";
        };
        # EasyTier listener ports: module-owned (modules/nixos/easytier.nix).
        # Derived from cfg.listeners URIs — no per-host/per-gateway duplication.
      };
    };
  })

  # ── Edge role defaults ──────────────────────────────────────────
  (lib.mkIf (cfg.enable && cfg.edge.enable) {
    osf.gateway.watchdog.services = lib.mkDefault {
      tcp-over-redis = {
        unit = "tcp-over-redis-client.service";
      };
      sing-box-tproxy = {
        unit = "sing-box-tproxy.service";
      };
    };
  })

  # Tproxy port registration removed: sing-box-tproxy now uses a TUN inbound
  # (auto_redirect), not a listening tproxy port. No firewall port to open.

  # ── Core role services (P1 #3: default to mesh, not public) ────
  (lib.mkIf (cfg.enable && cfg.core.enable) {
    osf.network.services = {
      sing-box-router = {
        port = 26100;
        proto = "tcp";
        allow = [ "mesh" ];
        desc = "sing-box core router";
      };
      clash-api = {
        port = 26110;
        proto = "tcp";
        allow = [ "mesh" ];
        desc = "Clash API dashboard";
      };
    };

    osf.gateway.watchdog.services = lib.mkDefault {
      tcp-over-redis = {
        unit = "tcp-over-redis-server.service";
      };
    };
  })

  # ── Edge blackhole (unchanged logic, now via extraTables) ───────
  (lib.mkIf (cfg.enable && cfg.edge.enable && cfg.edge.coreRouterPublicIp != null) {
    osf.network.extraTables.gateway-edge-blackhole = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority 0; policy accept;
          ip daddr ${cfg.edge.coreRouterPublicIp} tcp dport 11010 drop comment "force ET through mux tunnel"
          ip daddr ${cfg.edge.coreRouterPublicIp} udp dport 11010 drop comment "force ET through mux tunnel"
        }
      '';
    };
  })
]
