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
    #
    # Cutover race, two faces (2026-07-03): on sing-box gateways both DNS
    # (:53 inbound) AND the data path to api.tailscale.com (CN hosts reach
    # it only through the warm tproxy chain) come up with sing-box. This
    # oneshot has no Restart=, so one race = permanently failed unit
    # (activation status 4). Signatures: 'read udp 127.0.0.1:53: connection
    # refused' (volcengine-gz, DNS face) and 'Post api.tailscale.com/...:
    # EOF' (volcengine-sh, cold-data-path face). Guards: (a) order after
    # the sing-box gateway service when present — its start job completes
    # only after the ExecStartPost dig-poll, so this covers BOTH faces;
    # (b) a bounded ExecStartPre resolver wait for the poll's give-up
    # fallback, crash windows, and non-gateway hosts (DNS face only) —
    # loud failure after the budget, never a silent race.
    systemd.services.tailscale-auth = {
      description = "Tailscale auto-auth";
      after = [
        "network-online.target"
        "tailscaled.service"
      ]
      ++ lib.optional (config.osf.sing-box-gateway.enable or false
      ) "${config.osf.sing-box-gateway.serviceName}.service";
      wants = [
        "network-online.target"
        "tailscaled.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = pkgs.writeShellScript "tailscale-auth-wait-dns" ''
          for i in $(seq 1 30); do
            if ${pkgs.glibc.bin}/bin/getent hosts api.tailscale.com >/dev/null 2>&1; then
              exit 0
            fi
            echo "tailscale-auth: waiting for DNS (api.tailscale.com), attempt $i/30"
            sleep 1
          done
          echo "tailscale-auth: DNS still not resolving api.tailscale.com after 30s" >&2
          exit 1
        '';
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
