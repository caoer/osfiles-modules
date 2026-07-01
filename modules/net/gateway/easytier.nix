# modules/net/gateway/easytier.nix — Gateway shim for EasyTier.
#
# Activates the standalone osf.easytier module with the gateway hostname.
# IP, peers, and subnets all come from mesh.nix via the standalone
# module's defaults — no pass-through needed.  Host configs can still
# override via osf.easytier.{ip,peers,subnets} when they diverge from
# mesh.nix.
{ config, lib, ... }:
let
  cfg = config.osf.gateway;
in
lib.mkIf cfg.enable {
  osf.easytier = {
    enable = true;
    inherit (cfg) hostname;
  };
}
