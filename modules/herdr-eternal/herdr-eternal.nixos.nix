# modules/herdr-eternal/herdr-eternal.nixos.nix — herdr-eternal-server on a
# NixOS host: the core unit (./core.nix) plus the package defaults from this
# flake's herdr-eternal and herdr inputs and the firewall hole on the mesh
# interface the listener binds. The one source for osfiles and member repos
# alike (in nixosModules.default).
#
#   osf.herdrEternal = {
#     enable = true;
#     user = "<owner>";
#     listen = "<mesh-ip>:7433";
#     interface = "tun0";
#     meshUnit = "easytier.service";
#     tokenFile = config.sops.secrets.herdr_eternal_token.path;
#   };
{ herdrEternalFlake, herdrFlake }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.herdrEternal;
  portOf = addr: lib.toInt (lib.last (lib.splitString ":" addr));
  port = portOf cfg.listen;
in
{
  imports = [ ./core.nix ];

  options.osf.herdrEternal = {
    interface = lib.mkOption {
      type = lib.types.str;
      example = "tun0";
      description = "Interface carrying the listen address; TCP <port> is opened on it alone.";
    };
    quic.interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "enp0s8";
      description = "Interface carrying quic.listen; its UDP port is opened on it alone.";
    };
  };

  config = lib.mkIf cfg.enable {
    osf.herdrEternal.package =
      lib.mkDefault
        herdrEternalFlake.packages.${pkgs.stdenv.hostPlatform.system}.default;
    # The fleet herdr pin: the same version the mac runs.
    osf.herdrEternal.herdrPackage =
      lib.mkDefault
        herdrFlake.packages.${pkgs.stdenv.hostPlatform.system}.herdr;
    networking.firewall.interfaces = lib.mkMerge [
      { ${cfg.interface}.allowedTCPPorts = [ port ]; }
      (lib.mkIf (cfg.quic.listen != null) {
        ${cfg.quic.interface}.allowedUDPPorts = [ (portOf cfg.quic.listen) ];
      })
    ];
  };
}
