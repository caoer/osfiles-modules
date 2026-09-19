# modules/net/gateway/sing-box-sor-client.nix — Isolated SoR sing-box instances.
#
# Runs a separate sing-box process using the SoR fork (redis-pubsub transport)
# on a loopback mixed port. The main tproxy sing-box references each as a
# regular proxy outbound (socks5 to loopback:PORT), so a SoR crash only loses
# one outbound — not the entire transparent proxy.
#
# Two option surfaces feed the same unit builder:
#   osf.gateway.edge.sorClient          — the single legacy instance (sor-mux-cd)
#   osf.gateway.edge.sorClients.<name>  — one instance per core-side service
#
# Gated on: cfg.enable && ecfg.enable; the legacy unit also on sorCfg.enable.
{
  config,
  lib,
  pkgs,
  osfLib,
  ...
}:
let
  wk = osfLib.wellKnown;

  cfg = config.osf.gateway;
  ecfg = cfg.edge;
  sorCfg = ecfg.sorClient;

  # ── Unit builder ───────────────────────────────────────────────────
  # `inst` carries listenPort, serviceName, redisUrl, muxPassword, package,
  # systemdName, logLevel — the shape both option surfaces share.
  mkUnit =
    description: inst:
    let
      # ── Config generation ────────────────────────────────────────────
      # Minimal sing-box config: mixed inbound on loopback → redis-pubsub
      # outbound. No TUN, no geo rules, no auto_redirect — just a local proxy
      # endpoint.
      sorOutbound = {
        type = "shadowsocks";
        tag = "to-core-sor";
        server = "unused";
        server_port = 0;
        domain_resolver = "dns-direct";
        method = "2022-blake3-aes-256-gcm";
        password = inst.muxPassword;
        multiplex = {
          enabled = true;
          protocol = "smux";
          padding = true;
          max_connections = 4;
          min_streams = 2;
        };
        transport = {
          type = "redis-pubsub";
          redis_url = inst.redisUrl;
          service_name = inst.serviceName;
          send_window_size = 33554432;
          channel_buffer_size = 256;
          max_publish_size = 524288;
        };
      };

      generatedConfig = {
        log = {
          level = inst.logLevel;
          timestamp = true;
        };
        dns = {
          servers = [
            {
              type = "udp";
              tag = "dns-direct";
              server = wk.dns.alidns;
            }
          ];
          final = "dns-direct";
        };
        inbounds = [
          {
            type = "mixed";
            tag = "mixed-in";
            listen = wk.localhost;
            listen_port = inst.listenPort;
          }
        ];
        outbounds = [
          sorOutbound
          {
            type = "direct";
            tag = "direct";
          }
        ];
        route = {
          rules = [
            {
              protocol = "dns";
              action = "hijack-dns";
            }
            {
              ip_is_private = true;
              action = "route";
              outbound = "direct";
            }
          ];
          final = "to-core-sor";
          auto_detect_interface = true;
          default_domain_resolver = "dns-direct";
        };
        experimental = {
          cache_file = {
            enabled = true;
            path = "/var/lib/${inst.systemdName}/cache.db";
          };
        };
      };

      configFile = pkgs.writeText "${inst.systemdName}.json" (builtins.toJSON generatedConfig);

      # ── Private resolver for the redis-pubsub transport ──────────────
      # sing-box-sor dials its redis_url host via Go's net.Dial (system
      # /etc/resolv.conf), NOT the sing-box `dns` block above. On edge hosts
      # /etc/resolv.conf points at the tproxy's :53 (loopback), which is
      # ordered to start AFTER this service — so at cold boot the redis host
      # would be unresolvable. Bind a private resolv.conf (direct upstream)
      # into this unit's namespace only, so it never mutates the host's
      # split-DNS file (a global write would knock the gateway off :53 on
      # every sor-client restart).
      resolvConf = pkgs.writeText "${inst.systemdName}-resolv.conf" ''
        nameserver ${wk.dns.alidns}
      '';
    in
    {
      inherit description;
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStartPre = "${inst.package}/bin/sing-box check -c ${configFile}";
        ExecStart = "${inst.package}/bin/sing-box -D /var/lib/${inst.systemdName} run -c ${configFile}";
        Restart = "on-failure";
        RestartSec = 3;
        LimitNOFILE = 65536;
        StateDirectory = inst.systemdName;
        DynamicUser = true;
        # Private /etc/resolv.conf so the redis-pubsub transport resolves its
        # redis host without depending on the tproxy's :53 (see resolvConf).
        BindReadOnlyPaths = [ "${resolvConf}:/etc/resolv.conf" ];
      };
      # No restartTriggers needed: configFile and resolvConf are
      # content-addressed store paths embedded in the unit, so any config
      # change restarts on switch.
    };

in
lib.mkIf (cfg.enable && ecfg.enable) {
  systemd.services =
    lib.optionalAttrs sorCfg.enable {
      ${sorCfg.systemdName} = mkUnit "sing-box SoR client (redis-pubsub to core router, isolated)" sorCfg;
    }
    // lib.mapAttrs' (
      name: inst:
      lib.nameValuePair inst.systemdName (
        mkUnit "sing-box SoR client ${name} (redis-pubsub service ${inst.serviceName}, isolated)" inst
      )
    ) ecfg.sorClients;
}
