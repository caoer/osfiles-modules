# modules/net/gateway/tcp-over-redis-server.nix — tcp-over-redis server.
#
# Terminates tunnels from edge gateways. Each service maps a Redis channel
# to a local target (e.g. sing-box instance).
#
# Gated on: cfg.enable && cfg.core.enable
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.gateway;
  ccfg = cfg.core;
  torCfg = ccfg.tcpOverRedis;

  tcpOverRedisPkg = cfg.tcpOverRedisPackage;

  serverServices = map (svc: {
    inherit (svc) name;
    inherit (svc) target;
  }) torCfg.services;

  configFile = pkgs.writeText "tcp-over-redis-server.json" (
    builtins.toJSON {
      redis_url = torCfg.redisUrl;
      send_window_size = 33554432;
      buffer_size = 65536;
      channel_buffer_size = 256;
      max_publish_size = 524288;
      services = serverServices;
    }
  );

in
lib.mkIf (cfg.enable && ccfg.enable) {
  systemd.services.tcp-over-redis-server = {
    description = "tcp-over-redis server (terminate tunnels from edge gateways)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${tcpOverRedisPkg}/bin/tcp-over-redis server --config ${configFile}";
      Restart = "always";
      RestartSec = 2;
      LimitNOFILE = 1048576;
    };
  };
}
