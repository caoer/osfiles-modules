# modules/net/gateway/tcp-over-redis.nix — tcp-over-redis client tunnel.
#
# Bridges local sing-box mux listeners to Redis pub/sub, providing the
# transport layer for the edge↔core proxy chain.
#
# Gated on: cfg.enable && cfg.edge.enable
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.osf.gateway;
  ecfg = cfg.edge;
  torCfg = ecfg.tcpOverRedis;

  tcpOverRedisPkg = cfg.tcpOverRedisPackage;

  clientServices = map (svc: {
    inherit (svc) name;
    inherit (svc) listen;
  }) torCfg.services;

  configText = builtins.toJSON {
    client_id = torCfg.clientId;
    redis_url = torCfg.redisUrl;
    send_window_size = 33554432;
    buffer_size = 65536;
    channel_buffer_size = 256;
    max_publish_size = 524288;
    services = clientServices;
  };

  # A redis URL given as a sops placeholder renders the config as a sops
  # template, root-only at activation; otherwise it stays a store file.
  secretConfig = import ../../../lib/secretConfig.nix { inherit lib; };
  templated = secretConfig.hasPlaceholder configText;
  configFile =
    if templated then
      config.sops.templates."tcp-over-redis-client.json".path
    else
      pkgs.writeText "tcp-over-redis-client.json" configText;

in
lib.mkIf (cfg.enable && ecfg.enable) (
  {
    systemd.services.tcp-over-redis-client = {
      description = "tcp-over-redis client (Redis tunnel to core router)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${tcpOverRedisPkg}/bin/tcp-over-redis client --config ${configFile}";
        Restart = "always";
        RestartSec = 2;
        LimitNOFILE = 1048576;
      };
    };

  }
  # Hosts without sops-nix never carry a placeholder; they get no sops option.
  // lib.optionalAttrs (options ? sops) {
    sops.templates = lib.mkIf templated {
      "tcp-over-redis-client.json" = {
        content = configText;
        restartUnits = [ "tcp-over-redis-client.service" ];
      };
    };
  }
)
