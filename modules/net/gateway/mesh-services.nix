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
    dns-tcp = {
      port = 53;
      proto = "tcp";
      tier = "both";
      desc = "sing-box DNS";
    };
    dns-udp = {
      port = 53;
      proto = "udp";
      tier = "both";
      desc = "sing-box DNS";
    };
    easytier-rpc = {
      port = 15600; # osfiles lib/osf/mesh.nix rpcPortal
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
  (lib.mkIf (cfg.enable && cfg.core.enable) {
    osf.gateway.meshServices = coreServices;
  })
]
