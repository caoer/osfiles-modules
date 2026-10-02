# modules/net/gateway/tcp-over-redis-server.nix — tcp-over-redis server.
#
# Terminates tunnels from edge gateways. Each service maps a Redis channel
# to a local target (e.g. sing-box instance).
#
# Gated on: cfg.enable && cfg.core.enable
{
  config,
  lib,
  options,
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

  configText = builtins.toJSON {
    redis_url = torCfg.redisUrl;
    send_window_size = 33554432;
    buffer_size = 65536;
    channel_buffer_size = 256;
    max_publish_size = 524288;
    services = serverServices;
  };

  # A redis URL given as a sops placeholder renders the config as a sops
  # template, root-only at activation; otherwise it stays a store file.
  secretConfig = import ../../../lib/secretConfig.nix { inherit lib; };
  templated = secretConfig.hasPlaceholder configText;
  configFile =
    if templated then
      config.sops.templates."tcp-over-redis-server.json".path
    else
      pkgs.writeText "tcp-over-redis-server.json" configText;

in
lib.mkIf (cfg.enable && ccfg.enable) (
  {
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
  # Hosts without sops-nix never carry a placeholder; they get no sops option.
  // lib.optionalAttrs (options ? sops) {
    sops.templates = lib.mkIf templated {
      "tcp-over-redis-server.json" = {
        content = configText;
        restartUnits = [ "tcp-over-redis-server.service" ];
      };
    };
  }
)
