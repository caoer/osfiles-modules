# modules/net/tailscale.nix — Tailscale overlay network (osf.tailscale).
#
# Standalone module, extracted from the gateway bundle so any NixOS host can
# opt in independently — and downstream consumers that manage tailscale
# themselves (e.g. coscene-nix-nixos cos.tailscale) simply don't enable it,
# instead of mkForce-disabling a systemd service by name.
#
# Option surface mirrors modules/foreign/tailscale.nix (osf.tailscale on
# Foreign hosts) — same names, same defaults.
#
# The host declares the auth-key sops secret (default name
# tailscale-auth-key); this module only consumes the rendered path.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.tailscale;
in
{
  options.osf.tailscale = {
    enable = lib.mkEnableOption "Tailscale overlay network with declarative auth";

    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Hostname advertised to the tailnet.";
    };

    authKeyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/tailscale-auth-key";
      description = "Path to the auth key file (host declares the sops secret).";
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Accept routes advertised by other Tailscale nodes.";
    };

    acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Accept DNS configuration from Tailscale.";
    };

    advertiseTags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "tag:lan-servers" ];
      description = "ACL tags to advertise.";
    };

    advertiseExitNode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Advertise this node as a Tailscale exit node.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra CLI flags passed to tailscale up.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale.enable = true;

    # Exit node advertises IP:0_0_0_0/0 + ::/0 via tailscale0, which makes strict
    # rpfilter drop inbound eth0 packets (fib lookup returns tailscale0). Switch
    # to loose mode: source reachable via ANY interface, not necessarily the
    # arrival interface. Same fix as sing-box-tproxy.nix.
    networking.firewall.checkReversePath = lib.mkIf cfg.advertiseExitNode (lib.mkForce "loose");

    # IPv6 forwarding required for exit node (IPv4 forwarding set by gateway base).
    # Enabling forwarding disables SLAAC (accept_ra) by default — set accept_ra=2
    # to keep receiving Router Advertisements while forwarding, otherwise the IPv6
    # default route disappears and all IPv6 inbound breaks.
    boot.kernel.sysctl = lib.mkIf cfg.advertiseExitNode {
      "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
      "net.ipv6.conf.all.accept_ra" = lib.mkDefault 2;
      "net.ipv6.conf.default.accept_ra" = lib.mkDefault 2;
    };

    # One-shot auth on first boot / key rotation. Uses sops secret.
    systemd.services.tailscale-auth = {
      description = "Tailscale auto-auth";
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [
        "network-online.target"
        "tailscaled.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "tailscale-auth" ''
          # --reset makes this declarative: always converge to the flags below,
          # regardless of current BackendState (fixes stale "Running" + logged-out).
          ${pkgs.tailscale}/bin/tailscale up \
            --reset \
            --authkey="$(cat ${cfg.authKeyPath})" \
            --hostname=${cfg.hostname} \
            --advertise-tags=${lib.concatStringsSep "," cfg.advertiseTags} \
            --accept-dns=${lib.boolToString cfg.acceptDns} \
            --accept-routes=${lib.boolToString cfg.acceptRoutes}${lib.optionalString cfg.advertiseExitNode " \\\n          --advertise-exit-node"}${
              lib.optionalString (cfg.extraFlags != [ ]) (
                " \\\n          " + lib.concatStringsSep " " cfg.extraFlags
              )
            }
        '';
      };
    };
  };
}
