# modules/net/gateway/watchdog.nix — eBPF tunnel watchdog systemd service.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.gateway;
  wcfg = cfg.watchdog;

  configTemplate = pkgs.writeText "watchdog-config-template.json" (
    builtins.toJSON {
      monitor_ports = wcfg.monitorPorts;
      inherit (wcfg) services;
      thresholds = {
        retransmit_degraded = 5;
        retransmit_critical = 20;
        window_seconds = 10;
        health_degraded = 0.7;
        health_critical = 0.3;
        silence_timeout_seconds = 60;
      };
      recovery = {
        cooldown_seconds = wcfg.cooldownSeconds;
        backoff_max_seconds = 3600;
        open_threshold_count = 3;
        open_threshold_window_seconds = 1800;
        grace_period_seconds = 30;
      };
      redis_addr = wcfg.redisAddr;
      alert_webhook_url = "WEBHOOK_PLACEHOLDER";
      dry_run = wcfg.dryRun;
    }
  );

  watchdogPkg = pkgs.watchdog;

in
lib.mkIf (cfg.enable && wcfg.enable) {

  sops.secrets.watchdog-webhook = lib.mkIf (wcfg.alertWebhookSecret != null) {
    sopsFile = config.osf.secretsPath;
    key = wcfg.alertWebhookSecret;
  };

  systemd.services.tunnel-watchdog = {
    description = "eBPF TCP tunnel health monitor";
    after = [
      "network-online.target"
      "sing-box-tproxy.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStartPre =
        let
          script = pkgs.writeShellScript "watchdog-inject-config" ''
            cp ${configTemplate} /run/tunnel-watchdog/config.json
            chmod 640 /run/tunnel-watchdog/config.json

            ${lib.optionalString (wcfg.alertWebhookSecret != null) ''
              for i in $(seq 1 30); do
                [ -s /run/secrets/watchdog-webhook ] && break
                sleep 1
              done
              if [ -s /run/secrets/watchdog-webhook ]; then
                WEBHOOK=$(cat /run/secrets/watchdog-webhook)
                ${pkgs.gnused}/bin/sed -i "s|WEBHOOK_PLACEHOLDER|$WEBHOOK|" \
                  /run/tunnel-watchdog/config.json
              fi
            ''}
          '';
        in
        "+${script}";

      ExecStart =
        "${watchdogPkg}/bin/tunnel-watchdog --config /run/tunnel-watchdog/config.json"
        + lib.optionalString wcfg.dryRun " --dry-run"
        + " --log-level ${wcfg.logLevel}";

      RuntimeDirectory = "tunnel-watchdog";

      Restart = "always";
      RestartSec = 10;

      # Phase 1: tracepoints only. CAP_SYS_ADMIN deferred to Phase 3 (sock_ops).
      AmbientCapabilities = [
        "CAP_BPF"
        "CAP_PERFMON"
        "CAP_NET_ADMIN"
      ];
      CapabilityBoundingSet = [
        "CAP_BPF"
        "CAP_PERFMON"
        "CAP_NET_ADMIN"
      ];
      NoNewPrivileges = true;
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
}
