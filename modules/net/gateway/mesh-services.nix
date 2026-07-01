# modules/net/gateway/mesh-services.nix — Mesh service exposure registry.
#
# Base services (all gateways) + role-specific services (edge/core).
# Firewall reads meshServices to open ports.
#
# Trust tiers:
#   trusted  — only mesh peers should reach it (proxy, management)
#   both     — mesh peers AND local LAN (DNS)
#   internal — must NOT be reachable from mesh (upstream DNS, diagnostics)
{ config, lib, ... }:
let
  cfg = config.osf.gateway;

  # ── Shared services (all gateways) ──────────────────────────────
  baseServices = {
    ssh = {
      port = 22;
      proto = "tcp";
      tier = "trusted";
      desc = "SSH";
    };
    adguard-ui = {
      port = 3000;
      proto = "tcp";
      tier = "both";
      desc = "AdGuard Home UI";
    };
    dns-tcp = {
      port = 53;
      proto = "tcp";
      tier = "both";
      desc = "AdGuard DNS";
    };
    dns-udp = {
      port = 53;
      proto = "udp";
      tier = "both";
      desc = "AdGuard DNS";
    };
    mosdns-tcp = {
      port = 5353;
      proto = "tcp";
      tier = "internal";
      desc = "MosDNS (AdGuard upstream)";
    };
    mosdns-udp = {
      port = 5353;
      proto = "udp";
      tier = "internal";
      desc = "MosDNS (AdGuard upstream)";
    };
    easytier-rpc = {
      port = 15888;
      proto = "tcp";
      tier = "internal";
      desc = "EasyTier RPC (localhost only)";
    };
  };

  # ── Core role services ──────────────────────────────────────────
  coreServices = {
    sing-box-router = {
      port = 26100;
      proto = "tcp";
      tier = "trusted";
      desc = "sing-box core router inbound";
    };
    clash-api = {
      port = 26110;
      proto = "tcp";
      tier = "trusted";
      desc = "sing-box Clash API dashboard";
    };
  };

in
lib.mkMerge [
  (lib.mkIf cfg.enable {
    osf.gateway.meshServices = baseServices;
  })
  (lib.mkIf (cfg.enable && cfg.edge.enable) {
    # Edge watchdog defaults: monitor the tunnel chain
    osf.gateway.watchdog.services = lib.mkDefault {
      tcp-over-redis = {
        unit = "tcp-over-redis-client.service";
      };
      sing-box-tproxy = {
        unit = "sing-box-tproxy.service";
      };
    };
  })
  (lib.mkIf (cfg.enable && cfg.core.enable) {
    osf.gateway.meshServices = coreServices;
    # Core watchdog defaults: monitor the server
    osf.gateway.watchdog.services = lib.mkDefault {
      tcp-over-redis = {
        unit = "tcp-over-redis-server.service";
      };
    };
  })
]
