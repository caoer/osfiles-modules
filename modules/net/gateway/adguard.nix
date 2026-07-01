# modules/net/gateway/adguard.nix — AdGuard Home DNS frontend.
#
# Per-host rewrites via osf.gateway.adguard.extraRewrites.
{
  config,
  lib,
  osfLib,
  ...
}:
let
  wk = osfLib.wellKnown;

  cfg = config.osf.gateway;

  rewrites = map (r: {
    inherit (r) domain answer;
    enabled = true;
  }) cfg.adguard.extraRewrites;
in
lib.mkIf (cfg.enable && cfg.adguard.enable) {
  # DynamicUser conflicts with impermanence bind mounts on /var/lib/AdGuardHome.
  # Systemd tries to migrate the dir to /var/lib/private/ but can't move a mount point.
  systemd.services.adguardhome.serviceConfig.DynamicUser = lib.mkForce false;

  services.adguardhome = {
    enable = true;
    mutableSettings = false;
    settings = {
      users = [
        {
          name = "admin";
          password = cfg.adguard.passwordHash;
        }
      ];
      auth_attempts = 5;
      block_auth_min = 15;
      http = {
        address = "${wk.anyAddr}:3000";
        session_ttl = "720h";
      };
      dns = {
        bind_hosts = [ wk.anyAddr ];
        port = 53;
        upstream_dns = [ "${wk.localhost}:5353" ];
        upstream_mode = "load_balance";
        bootstrap_dns = [
          wk.dns.alidns
          wk.dns.dnspod
        ];
        # Gateway serves mesh clients, not public internet — no rate limit.
        ratelimit = 0;
        refuse_any = true;
        cache_size = 0;
        cache_enabled = false;
        max_goroutines = 300;
        handle_ddr = true;
        upstream_timeout = "10s";
        trusted_proxies = [
          wk.loopbackCidr
          "::1/128"
        ];
      };
      querylog = {
        enabled = true;
        file_enabled = true;
        interval = "2160h";
        size_memory = 1000;
      };
      statistics = {
        enabled = true;
        interval = "24h";
      };
      filtering = {
        filtering_enabled = true;
        rewrites_enabled = true;
        inherit rewrites;
      };
    };
  };
}
