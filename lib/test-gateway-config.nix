# lib/test-gateway-config.nix — gateway-cq style config.
let
  nixpkgs = import <nixpkgs> { };
  lib = nixpkgs.lib;
  gen = import ./singbox-config-generator.nix { inherit lib; };

  result = gen {
    shadowtlsDefaults = {
      version = 3;
      sni = "swcdn.apple.com";
      ssMethod = "2022-blake3-aes-256-gcm";
      ssPassword = "7OgaMpBQEaoCZfloUI9E9uSzntPkYUDdWQnFskwu1P0=";
      password = "B5jcaxvcg/lAJfAjDjnTblGKGo3RSnMcB51CH7dzUy0=";
    };

    outboundGroups = {
      stls = {
        outbounds = [
          { tag = "bwg-megabox"; server = "144.34.230.170";                          port = 23061; shadowtls = true; }
          { tag = "bwg-nyc-gia"; server = "23.252.106.53";                           port = 23061; shadowtls = true; }
          { tag = "dmit-lax";    server = "2605:52c0:2:11b4:be24:11ff:fef8:c09";     port = 23061; shadowtls = true; }
          { tag = "dmit-lax-2";  server = "2605:52c0:2:347d:be24:11ff:fe74:adfa";    port = 23061; shadowtls = true; }
        ];
      };

      cfip-lan = {
        outbounds = [
          { type = "http";        tag = "cfip-mix-v6"; server = "192.168.80.204"; server_port = 7909; }
          { type = "shadowsocks"; tag = "cfip-ss-v6";  server = "192.168.80.204"; server_port = 7908; method = "2022-blake3-aes-128-gcm"; password = "vfqac0/1g0mfQ6wnnpJhdw=="; }
          { type = "http";        tag = "cfip-mix-v4"; server = "192.168.80.204"; server_port = 7899; }
          { type = "shadowsocks"; tag = "cfip-ss-v4";  server = "192.168.80.204"; server_port = 7898; method = "2022-blake3-aes-128-gcm"; password = "vfqac0/1g0mfQ6wnnpJhdw=="; }
        ];
      };

      gateway-cd = {
        outbounds = [
          {
            type = "shadowsocks"; tag = "to-core-rs"; server = "127.0.0.1"; server_port = 10820;
            method = "2022-blake3-aes-256-gcm"; password = "2sKQrZs7o1PBlU+DYweGfvt31//4sHLJsD3FeSU9kus=";
            multiplex = { enabled = true; protocol = "smux"; padding = true; max_connections = 4; min_streams = 2; };
          }
          {
            type = "shadowsocks"; tag = "to-core-sor"; server = "unused"; server_port = 0;
            method = "2022-blake3-aes-256-gcm"; password = "2sKQrZs7o1PBlU+DYweGfvt31//4sHLJsD3FeSU9kus=";
            multiplex = { enabled = true; protocol = "smux"; padding = true; max_connections = 4; min_streams = 2; };
            transport = {
              type = "redis-pubsub"; redis_url = "redis://default:REDACTED@r-redis.cn-chengdu.rds.aliyuncs.com:6379";
              service_name = "sor-mux-cd"; send_window_size = 33554432; channel_buffer_size = 256; max_publish_size = 524288;
            };
          }
        ];
      };

      coscene-hq = {
        urltest = false; inMainPool = false;
        outbounds = [
          { type = "shadowsocks"; tag = "coscene-hq"; server = "office-gateway-cn.coscene.cn"; server_port = 31081; method = "2022-blake3-aes-128-gcm"; password = "zyef3NDYUovAltzHlDge+Q=="; }
        ];
      };

      coscene-stex = {
        urltest = false; inMainPool = false;
        outbounds = [
          { type = "shadowsocks"; tag = "coscene-stex"; server = "cos-stex.coscene.dynv6.net"; server_port = 31081; method = "2022-blake3-aes-128-gcm"; password = "zyef3NDYUovAltzHlDge+Q=="; }
        ];
      };
    };

    dnsDetour = "stls";

    route_exclude_address = [ "223.5.5.5/32" "119.29.29.29/32" "100.100.100.101/32" "10.144.144.1/32" "10.144.144.2/32" ];

    extraRouteRules = [
      { domain_suffix = [ ".coscene.tech" ]; action = "route"; outbound = "coscene-hq"; }
      { ip_cidr = [ "192.168.89.0/24" ]; action = "route"; outbound = "coscene-hq"; }
      { ip_cidr = [ "192.168.90.0/24" ]; action = "route"; outbound = "coscene-stex"; }
    ];

    clashApi = { port = 9090; host = "0.0.0.0"; secret = "CLASH_SECRET_PLACEHOLDER"; };
    apiService = { port = 9091; host = "0.0.0.0"; secret = "CLASH_SECRET_PLACEHOLDER"; dashboardPath = "/var/lib/sing-box-tproxy/dashboard"; };

    geoCnPath = "/nix/store/placeholder-geo-cn.json";
  };

in
result
