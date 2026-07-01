# modules/net/gateway/tcp-over-redis.nix — tcp-over-redis client tunnel.
#
# Bridges local sing-box mux listeners to Redis pub/sub, providing the
# transport layer for the edge↔core proxy chain.
#
# Gated on: cfg.enable && cfg.edge.enable
{
  config,
  lib,
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

  configFile = pkgs.writeText "tcp-over-redis-client.json" (
    builtins.toJSON {
      client_id = torCfg.clientId;
      redis_url = torCfg.redisUrl;
      send_window_size = 33554432;
      buffer_size = 65536;
      channel_buffer_size = 256;
      max_publish_size = 524288;
      services = clientServices;
    }
  );

in
lib.mkIf (cfg.enable && ecfg.enable) {
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
