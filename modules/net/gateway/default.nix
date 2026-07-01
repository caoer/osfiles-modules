# modules/net/gateway/default.nix — mesh gateway service bundle.
#
# Imports all sub-modules. Each guards itself:
#   cfg.enable       → shared services (adguard, mosdns, easytier, base firewall)
#
# Tailscale is NOT part of this bundle — it's the standalone osf.tailscale
# module (modules/nixos/tailscale.nix); gateway hosts opt in per-host.
#   cfg.edge.enable  → edge role (tproxy + tcp-over-redis tunnel to core router)
#   cfg.core.enable  → core role (tcp-over-redis server)
{ ... }:
{
  imports = [
    ./options.nix
    # ── Shared (gated on cfg.enable) ───────
    ./easytier.nix
    ./mosdns.nix
    ./adguard.nix
    ./firewall.nix
    ./network-defaults.nix
    ./watchdog.nix
    ./mesh-services.nix
    # ── Edge role (gated on cfg.edge.enable) ───────
    ./sing-box-tproxy.nix
    ./sing-box-sor-client.nix
    ./tcp-over-redis.nix
    # ── Core role (gated on cfg.core.enable) ───────
    ./tcp-over-redis-server.nix
  ];
}
