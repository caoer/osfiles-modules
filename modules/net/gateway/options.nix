# modules/net/gateway/options.nix — osf.gateway.* option declarations.
#
# Three tiers:
#   osf.gateway.enable        — shared infra (EasyTier, AdGuard, MosDNS)
#   osf.gateway.edge.enable   — edge role: tproxy + tunnel traffic TO a core router
#   osf.gateway.core.enable   — core role: terminate tunnels FROM edge gateways
{
  config,
  lib,
  osfLib,
  ...
}:
let
  wk = osfLib.wellKnown;

  inherit (lib) mkEnableOption mkOption types;

  meshServiceModule = types.submodule {
    options = {
      port = mkOption {
        type = types.port;
        description = "Service port.";
      };
      proto = mkOption {
        type = types.enum [
          "tcp"
          "udp"
        ];
        description = "Protocol.";
      };
      tier = mkOption {
        type = types.enum [
          "trusted"
          "both"
          "internal"
        ];
        description = "Trust tier: trusted (mesh-only), both (mesh+LAN), internal (block from mesh).";
      };
      desc = mkOption {
        type = types.str;
        description = "Human-readable service name.";
      };
    };
  };

  torServiceModule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Service name (matches tcp-over-redis channel name).";
      };
      listen = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Client mode: local listen address (e.g. ${wk.localhost}:10810).";
      };
      target = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Server mode: local target address (e.g. ${wk.localhost}:26101).";
      };
    };
  };
in
{
  options.osf.gateway = {
    enable = mkEnableOption "mesh gateway shared services (EasyTier, AdGuard, MosDNS)";

    hostname = mkOption {
      type = types.str;
      default = "";
      description = "Gateway hostname for EasyTier instance.";
    };

    # ── NAT (optional — only gateways routing for other hosts) ───────
    natInternalInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "eth0";
      description = "Internal interface for NAT (e.g. virbr0 side). Null disables NAT.";
    };

    natExternalInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "eth1";
      description = "External interface for NAT (e.g. LAN side). Null disables NAT.";
    };

    lanSubnets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "LAN CIDRs allowed to reach 'both'-tier services (DNS, AdGuard UI). Mesh subnets are always included.";
    };

    # ── Parameterized shared services ────────────────────────────────
    tailnetName = mkOption {
      type = types.str;
      example = "example-tailnet.ts.net";
      description = ''
        Tailscale tailnet DNS name. Queries under it are resolved via MagicDNS
        (MosDNS) and routed direct in the tproxy. Consumer-provided.
      '';
    };

    tcpOverRedisPackage = mkOption {
      type = types.package;
      description = ''
        tcp-over-redis package (client + server binaries). No public default —
        consumers provide their own build. Used by the edge tunnel client and
        the core tunnel server.
      '';
    };

    dns = {
      foreignUpstreams = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "https://${wk.dns.google}/dns-query"
          "https://${wk.dns.cloudflare}/dns-query"
        ];
        description = ''
          Upstream DNS servers for non-CN domain resolution.
          CN gateways: mesh IPs of a foreign relay (via EasyTier).
          Non-CN gateways: DoH URLs for direct resolution.
          Consumer-provided (e.g. via mkDefault in a fleet-wide module).
        '';
      };
    };

    adguard = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable AdGuard Home DNS frontend. Disable when sing-box handles DNS directly.";
      };

      passwordHash = mkOption {
        type = types.str;
        example = "$2y$10$...";
        description = ''
          bcrypt hash of the AdGuard Home admin password
          (generate: htpasswd -B -n -b admin <password>). Consumer-provided —
          never commit a hash derived from a real password to a public repo.
        '';
      };

      extraRewrites = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              domain = mkOption {
                type = types.str;
                description = "Domain to rewrite.";
              };
              answer = mkOption {
                type = types.str;
                description = "IP to resolve to.";
              };
            };
          }
        );
        default = [ ];
        description = "Per-host DNS rewrites for AdGuard Home.";
      };
    };

    mosdns = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable MosDNS split DNS resolver. Disable when sing-box handles DNS directly.";
      };

      region = mkOption {
        type = types.enum [
          "CN"
          "US"
        ];
        default = "CN";
        description = ''
          DNS region profile for the gateway.

          CN (default): split DNS for gateways inside the GFW — CN domains resolve
          via AliDNS/DNSPod, foreign domains via foreignUpstreams, with geosite/geoip
          rule downloads and GFW-poison (resp_ip) detection. Geodata is fetched at
          service start via AliDNS.

          US: plain fast resolution for gateways outside the GFW — every public
          domain resolves via foreignUpstreams (DoH). No geodata download, no CN
          split, no GFW-poison detection. Mesh-internal domains (et.net, k8s,
          tailscale, meshHosts) are still resolved locally. Use on US gateways:
          the CN geodata fetch resolves sources via AliDNS, which is slow/unreliable
          from the US and crash-loops the service.
        '';
      };

      extraCnDomains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "domain:aliyuncs.com"
          "domain:aliyun.com"
        ];
        description = "Extra domains forced to CN DNS resolution (bypasses geosite lookup).";
      };

      dropForeignAAAA = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Return NODATA for AAAA queries on foreign (non-CN) and unknown domains.
          Use on v4-only-egress gateways: the sing-box TUN proxies IPv4 only, so a
          foreign AAAA answer black-holes (no v6 proxy path) and the CN fallback can
          leak GFW-poisoned AAAA (2001::1). CN domains keep AAAA (native v6 egress).
        '';
      };

      meshHosts = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              ip = mkOption {
                type = types.str;
                description = "IP address.";
              };
              domain = mkOption {
                type = types.str;
                description = "Domain to resolve to this IP.";
              };
            };
          }
        );
        default = [ ];
        description = "Split DNS: domains resolved to mesh IPs for on-mesh clients.";
      };

      geodataUrls = {
        geositeCn = mkOption {
          type = types.str;
          description = "URL of the CN domain list (mosdns domain_set format). Consumer-provided.";
        };

        geositeNotCn = mkOption {
          type = types.str;
          default = "https://cdn.jsdelivr.net/gh/Loyalsoldier/domain-list-custom@release/geolocation-!cn.txt";
          description = "URL of the not-CN domain list (mosdns domain_set format).";
        };

        geoipCn = mkOption {
          type = types.str;
          description = "URL of the CN IP CIDR list (mosdns ip_set format). Consumer-provided.";
        };
      };
    };

    meshServices = mkOption {
      type = types.attrsOf meshServiceModule;
      default = { };
      description = "Mesh service exposure registry. Consumed by firewall rules.";
    };

    # ── Watchdog ─────────────────────────────────────────────────────
    watchdog = {
      enable = mkEnableOption "eBPF tunnel health watchdog";

      monitorPorts = mkOption {
        type = types.listOf types.port;
        default = [ 6379 ];
        description = "TCP ports to monitor for retransmits and state changes.";
      };

      redisAddr = mkOption {
        type = types.str;
        default = "${wk.localhost}:6379";
        description = "Redis address for pre-recovery health check.";
      };

      cooldownSeconds = mkOption {
        type = types.int;
        default = 120;
        description = "Minimum seconds between recovery attempts.";
      };

      dryRun = mkOption {
        type = types.bool;
        default = false;
        description = "Log recovery actions without executing them.";
      };

      logLevel = mkOption {
        type = types.enum [
          "debug"
          "info"
          "warn"
          "error"
        ];
        default = "info";
        description = "Log verbosity level.";
      };

      alertWebhookSecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "watchdog-webhook";
        description = "SOPS secret key for alert webhook URL. Null disables alerts.";
      };

      services = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              unit = mkOption {
                type = types.str;
                description = "Systemd unit name to restart on failure.";
              };
            };
          }
        );
        default = { };
        description = "Services the watchdog monitors and can restart. Defaults set per role.";
      };
    };

    # ── Edge role — tunnel TO a core router ──────────────────────────
    edge = {
      enable = mkEnableOption "edge gateway role (tunnel traffic to core router)";

      coreRouterPublicIp = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Public IP of the core router. Used to black-hole direct ET connections (force tunnel).";
      };

      tcpOverRedis = {
        clientId = mkOption {
          type = types.str;
          default = "";
          description = "tcp-over-redis client identifier.";
        };

        redisUrl = mkOption {
          type = types.str;
          default = "";
          description = "Redis connection URL for the tunnel.";
        };

        services = mkOption {
          type = types.listOf torServiceModule;
          default = [ ];
          description = "tcp-over-redis client service mappings (name → local listen).";
        };
      };

      muxPassword = mkOption {
        type = types.str;
        default = "";
        description = "Shadowsocks mux password for the tunnel to core router.";
      };

      # Canonical redis endpoint for the edge↔core tunnel transports
      # (tcp-over-redis and the SoR redis-pubsub client). Defaults from the
      # tcpOverRedis subtree for backward compatibility — hosts that set
      # tcpOverRedis.redisUrl inherit it here without changes. New consumers
      # should reference this, not the tcpOverRedis subtree.
      redisUrl = mkOption {
        type = types.str;
        default = config.osf.gateway.edge.tcpOverRedis.redisUrl;
        defaultText = lib.literalExpression "config.osf.gateway.edge.tcpOverRedis.redisUrl";
        description = "Canonical redis connection URL for edge tunnel transports.";
      };

      tunnelPort = mkOption {
        type = types.port;
        default = 10820;
        description = "Local tcp-over-redis listen port for ss-mux-cd tunnel.";
      };

      # ── Isolated SoR client (sing-box-over-redis) ──────────────────
      sorClient = {
        enable = mkEnableOption "isolated SoR sing-box client (redis-pubsub in a separate process)";

        package = mkOption {
          type = types.package;
          description = ''
            sing-box build with the redis-pubsub V2Ray transport (SoR fork).
            No public default — consumers provide their own build.
          '';
        };

        listenPort = mkOption {
          type = types.port;
          default = 10840;
          description = "Loopback mixed (HTTP+SOCKS) port for the SoR client. The main tproxy references this as a regular proxy outbound.";
        };

        redisUrl = mkOption {
          type = types.str;
          default = config.osf.gateway.edge.redisUrl;
          defaultText = lib.literalExpression "config.osf.gateway.edge.redisUrl";
          description = "Redis connection URL for the redis-pubsub transport. Defaults to the canonical edge-level redisUrl (not the tcpOverRedis subtree).";
        };

        muxPassword = mkOption {
          type = types.str;
          default = config.osf.gateway.edge.muxPassword;
          defaultText = lib.literalExpression "config.osf.gateway.edge.muxPassword";
          description = "Shadowsocks mux password for the SoR outbound.";
        };

        serviceName = mkOption {
          type = types.str;
          default = "sor-mux-cd";
          description = "Redis-pubsub service/channel name.";
        };

        systemdName = mkOption {
          type = types.str;
          default = "sing-box-sor-client";
          description = "Systemd service name for the SoR client.";
        };

        logLevel = mkOption {
          type = types.enum [
            "trace"
            "debug"
            "info"
            "warn"
            "error"
            "fatal"
            "panic"
          ];
          default = "info";
          description = "sing-box log level for the SoR client.";
        };
      };

      # ── Transparent proxy ──────────────────────────────────────────
      tproxy = {
        enable = mkEnableOption "transparent proxy for forwarded traffic";

        port = mkOption {
          type = types.port;
          default = 12345;
          description = "Tproxy inbound listen port.";
        };

        sourceSubnets = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Source CIDRs whose forwarded traffic gets transparently proxied.";
        };

        outboundGroups = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                outbounds = mkOption {
                  type = types.listOf (types.attrsOf types.anything);
                  default = [ ];
                  description = "Outbound definitions. Entries with `shadowtls = true` auto-expand.";
                };
                urltest = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Wrap group in urltest + selector. false for standalone exits.";
                };
                inMainPool = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Include in top-level proxy-select. false for targeted exits.";
                };
              };
            }
          );
          default = { };
          description = ''
            Outbound groups for the singbox-config-generator. Each group
            auto-gets a urltest + selector. The gateway-cd group (to-core-rs
            + to-core-sor) is always injected by the module.
          '';
        };

        outbounds = mkOption {
          type = types.listOf (types.attrsOf types.anything);
          default = [ ];
          description = "Extra standalone outbounds (no urltest/selector wrapping).";
        };

        routeRules = mkOption {
          type = types.listOf (types.attrsOf types.anything);
          default = [ ];
          description = "Extra route rules inserted before mesh/private catch-alls.";
        };

        dnsServers = mkOption {
          type = types.listOf (types.attrsOf types.anything);
          default = [ ];
          description = "Extra DNS servers appended to the tproxy sing-box dns.servers.";
        };

        dnsRules = mkOption {
          type = types.listOf (types.attrsOf types.anything);
          default = [ ];
          description = "Extra DNS rules inserted before the tun-in catch-all.";
        };

        finalOutbound = mkOption {
          type = types.str;
          default = "proxy-select";
          description = "Tag of the outbound used as route.final (the catch-all exit).";
        };

        clashApiPort = mkOption {
          type = types.nullOr types.port;
          default = null;
          example = 9090;
          description = ''
            When set, expose a Clash API + metacubexd dashboard for the tproxy
            sing-box on <clashApiHost>:<port>. Null disables it.
          '';
        };

        clashApiHost = mkOption {
          type = types.str;
          default = wk.localhost;
          example = wk.anyAddr;
          description = ''
            Bind address for the tproxy sing-box Clash API. Defaults to loopback.
            Set to ${wk.anyAddr} only with an auth secret (clash_api.secret) and a
            firewall rule scoping the port to trusted zones — the Clash API is
            an unauthenticated control plane otherwise.
          '';
        };
      };
    };

    # ── Core role — terminate tunnels FROM edge gateways ─────────────
    core = {
      enable = mkEnableOption "core router role (terminate tunnels from edge gateways)";

      tcpOverRedis = {
        redisUrl = mkOption {
          type = types.str;
          default = "";
          description = "Redis connection URL (typically VPC private endpoint).";
        };

        services = mkOption {
          type = types.listOf torServiceModule;
          default = [ ];
          description = "tcp-over-redis server service mappings (name → local target).";
        };
      };
    };
  };

  # ── Assertions — catch misconfiguration at eval time ─────────────
  config.assertions =
    let
      cfg = config.osf.gateway;
    in
    [
      {
        assertion = cfg.enable -> cfg.hostname != "";
        message = "osf.gateway.hostname must be set when gateway is enabled.";
      }
      {
        assertion = !(cfg.edge.enable && cfg.core.enable);
        message = "A gateway cannot be both edge and core simultaneously.";
      }
      {
        assertion = cfg.edge.enable -> cfg.edge.muxPassword != "";
        message = "osf.gateway.edge.muxPassword must be set when edge role is enabled.";
      }
      {
        assertion = cfg.edge.enable -> cfg.edge.tcpOverRedis.redisUrl != "";
        message = "osf.gateway.edge.tcpOverRedis.redisUrl must be set when edge role is enabled.";
      }
      {
        assertion = cfg.edge.enable -> cfg.edge.tcpOverRedis.clientId != "";
        message = "osf.gateway.edge.tcpOverRedis.clientId must be set when edge role is enabled.";
      }
      {
        assertion = cfg.core.enable -> cfg.core.tcpOverRedis.redisUrl != "";
        message = "osf.gateway.core.tcpOverRedis.redisUrl must be set when core role is enabled.";
      }
      {
        assertion =
          cfg.natInternalInterface == null && cfg.natExternalInterface == null
          || cfg.natInternalInterface != null && cfg.natExternalInterface != null;
        message = "osf.gateway: natInternalInterface and natExternalInterface must both be set or both be null.";
      }
    ];

  # ── Warnings — loud (non-fatal) signals for degraded configs ─────
  config.warnings =
    let
      cfg = config.osf.gateway;
    in
    lib.optional (cfg.enable && cfg.edge.enable && cfg.edge.tproxy.enable && !cfg.edge.sorClient.enable)
      "osf.gateway.edge: tproxy is enabled without sorClient — the gateway-cd outbound group runs single-route (to-core-rs only, no SoR failover). Enable osf.gateway.edge.sorClient for dual-transport failover.";
}
