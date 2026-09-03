# modules/herdr-eternal/herdr-eternal.nixos.nix — herdr-eternal-server on a
# NixOS member node: the core unit (./core.nix) plus the package default from
# this flake's herdr-eternal input and the firewall hole on the mesh
# interface the listener binds. Mirror of osfiles modules/nixos/herdr-eternal.nix.
#
#   osf.herdrEternal = {
#     enable = true;
#     user = "<owner>";
#     listen = "<mesh-ip>:7433";
#     interface = "tun0";
#     meshUnit = "easytier.service";
#     tokenFile = config.sops.secrets.herdr_eternal_token.path;
#   };
{ herdrEternalFlake }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.herdrEternal;
  port = lib.toInt (lib.last (lib.splitString ":" cfg.listen));
in
{
  imports = [ ./core.nix ];

  options.osf.herdrEternal.interface = lib.mkOption {
    type = lib.types.str;
    example = "tun0";
    description = "Interface carrying the listen address; TCP <port> is opened on it alone.";
  };

  config = lib.mkIf cfg.enable {
    osf.herdrEternal.package =
      lib.mkDefault
        herdrEternalFlake.packages.${pkgs.stdenv.hostPlatform.system}.default;
    networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = [ port ];
  };
}
