# modules/sing-box-gateway/sing-box-gateway.nixos.nix — Transparent proxy gateway via sing-box.
#
# Single TUN inbound (auto_route + auto_redirect) captures BOTH:
#   * gateway's own outbound traffic, and
#   * forwarded traffic from LAN/VM clients that use gateway as default route.
#
# DNS: split DNS built into sing-box — CN domains → AliDNS (direct), foreign
# domains → Cloudflare DoH (via proxy). DNS inbound on :53 serves LAN clients.
#
# Config generation delegated to singbox-config-generator (../../lib/).
# Host-specific options are passed through NixOS options; for routing/process/
# domain overrides, use extraGeneratorArgs (maps directly to generator params).
#
# Usage:
#   osf.sing-box-gateway = {
#     enable = true;
#     outboundGroups = { ... };
#     sourceSubnets = [ "192.168.80.0/24" ];
#     clashApi.enable = true;
#     clashApi.secretFile = config.sops.secrets.clash-api-secret.path;
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkForce
    types
    ;

  cfg = config.osf.sing-box-gateway;

  gen = (import ../../lib/singbox-config-generator.nix) { inherit lib; };

  singBoxPkg = cfg.package;
  dashboardPkg = cfg.dashboardPackage;

  clashOn = cfg.clashApi.enable;
  dashboardDir = "${cfg.stateDirectory}/dashboard";
  runtimeConfigPath = "/run/${cfg.serviceName}/config.json";
  configPath = if clashOn then runtimeConfigPath else configTemplate;
  hasSubnets = cfg.sourceSubnets != [ ];

  capabilities = [
    "CAP_NET_BIND_SERVICE" # DNS on :53
    "CAP_NET_ADMIN" # TUN creation, auto_redirect nftables
    "CAP_NET_RAW" # ICMP probes
  ];

  # ── Generate sing-box config ─────────────────────────────────────
  generated = gen (
    {
      inherit (cfg)
        outboundGroups
        finalOutbound
        shadowtlsDefaults
        extraOutbounds
        extraRouteRules
        ;

      tun_address = cfg.tunAddresses;
      route_exclude_address = cfg.routeExcludeAddresses;
      exclude_interface = cfg.excludeInterfaces;

      dnsDomestic = cfg.dns.domestic;
      dnsForeign = cfg.dns.foreign;
      dnsDetour = cfg.dns.detour;
      extraDnsServers = cfg.dns.extraServers;
      extraDnsRules = cfg.dns.extraRules;
      dnsCacheCapacity = cfg.dns.cacheCapacity;
      dnsReverseMapping = cfg.dns.reverseMapping;
      dnsListen = cfg.dns.listen;
      dnsListenAddress = cfg.dns.listenAddress;
      dnsListenPort = cfg.dns.listenPort;

      geoCnPath = cfg.geoCnPath;
      logLevel = cfg.logLevel;
      cacheFilePath = "${cfg.stateDirectory}/cache.db";

      clashApi =
        if clashOn then
          {
            port = cfg.clashApi.port;
            host = cfg.clashApi.host;
            secret = "CLASH_SECRET_PLACEHOLDER";
          }
        else
          null;
      apiService =
        if clashOn then
          {
            port = cfg.clashApi.port + 1;
            host = cfg.clashApi.host;
            secret = "CLASH_SECRET_PLACEHOLDER";
            dashboardPath = dashboardDir;
          }
        else
          null;
    }
    // cfg.extraGeneratorArgs
  );

  finalConfig = cfg.configPostProcess generated.config;

  configTemplate = pkgs.writeText "${cfg.serviceName}.json" (builtins.toJSON finalConfig);

  # ── Secret injection (Clash API) ─────────────────────────────────
  secretInjectionScript =
    let
      secretFile = cfg.clashApi.secretFile;
      script = pkgs.writeShellScript "${cfg.serviceName}-inject-secret" ''
        set -euo pipefail
        if ! test -s "${secretFile}"; then
          echo "${cfg.serviceName}: ${secretFile} missing or empty" >&2
          exit 1
        fi
        CLASH_SECRET=$(cat "${secretFile}")
        ${pkgs.jq}/bin/jq --arg s "$CLASH_SECRET" \
          '.experimental.clash_api.secret = $s | (.services[] | select(.secret == "CLASH_SECRET_PLACEHOLDER") | .secret) = $s' \
          ${configTemplate} > ${runtimeConfigPath}
      '';
    in
    "+${script}";

  # ── DNS lifecycle ────────────────────────────────────────────────
  # Bootstrap: domestic DNS in resolv.conf BEFORE sing-box starts, so
  # transports (redis-pubsub) can resolve via Go's net.Dial.
  dnsBootstrapScript = pkgs.writeShellScript "${cfg.serviceName}-dns-bootstrap" ''
    printf 'nameserver ${cfg.dns.domestic.server}\n' > /etc/resolv.conf
  '';
  # Restore: point system at sing-box's :53 AFTER it's up. Polls because
  # Type=simple — ExecStartPost races with sing-box init.
  dnsRestoreScript = pkgs.writeShellScript "${cfg.serviceName}-dns-restore" ''
    for i in $(seq 1 20); do
      if ${pkgs.dig}/bin/dig @127.0.0.1 +timeout=1 +tries=1 localhost >/dev/null 2>&1; then
        printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
        exit 0
      fi
      sleep 0.5
    done
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
  '';

in
{
  options.osf.sing-box-gateway = {
    enable = mkEnableOption "sing-box transparent proxy gateway (TUN + split DNS)";

    # ── Package ─────────────────────────────────────────────────────
    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../packages/sing-box.nix { };
      description = "sing-box package to use.";
    };

    dashboardPackage = mkOption {
      type = types.package;
      default = pkgs.metacubexd;
      description = "Clash API dashboard package (metacubexd).";
    };

    # ── Service identity ────────────────────────────────────────────
    serviceName = mkOption {
      type = types.str;
      default = "sing-box-tproxy";
      description = "systemd service name.";
    };

    stateDirectory = mkOption {
      type = types.str;
      default = "/var/lib/${cfg.serviceName}";
      description = "Persistent state directory (cache.db, dashboard).";
    };

    # ── TUN ─────────────────────────────────────────────────────────
    tunAddresses = mkOption {
      type = types.listOf types.str;
      default = [ "172.19.0.1/30" ];
      description = "TUN interface addresses (IPv4 and/or IPv6).";
    };

    routeExcludeAddresses = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "IPs excluded from TUN routing (DNS resolvers, mesh relay).";
    };

    excludeInterfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Network interfaces excluded from TUN routing.";
    };

    # ── Outbounds ───────────────────────────────────────────────────
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
              description = "Wrap group in urltest + selector.";
            };
            inMainPool = mkOption {
              type = types.bool;
              default = true;
              description = "Include in top-level proxy-select.";
            };
          };
        }
      );
      default = { };
      description = "Outbound groups for the config generator.";
    };

    extraOutbounds = mkOption {
      type = types.listOf (types.attrsOf types.anything);
      default = [ ];
      description = "Extra standalone outbounds (no urltest/selector wrapping).";
    };

    shadowtlsDefaults = mkOption {
      type = types.attrsOf types.anything;
      default = {
        version = 3;
        sni = "swcdn.apple.com";
        ssMethod = "2022-blake3-aes-256-gcm";
        ssPassword = "";
        password = "";
      };
      description = "Default ShadowTLS parameters for `shadowtls = true` entries.";
    };

    finalOutbound = mkOption {
      type = types.str;
      default = "proxy-select";
      description = "Tag of the catch-all route outbound.";
    };

    # ── Route rules ─────────────────────────────────────────────────
    # For directCidrs, directDomains, directProcessNames, findProcess:
    # use extraGeneratorArgs (e.g. extraGeneratorArgs.route_direct_cidrs).
    # Generator defaults: mesh CIDRs, .lockin.mesh/.et.net/.ts.net domains,
    # easytier/iperf process bypass.

    extraRouteRules = mkOption {
      type = types.listOf (types.attrsOf types.anything);
      default = [ ];
      description = "Extra route rules inserted before mesh/private catch-alls.";
    };

    # ── DNS ─────────────────────────────────────────────────────────
    dns = {
      domestic = mkOption {
        type = types.attrsOf types.anything;
        default = {
          type = "udp";
          tag = "dns-domestic";
          server = "223.5.5.5";
        };
        description = "Domestic DNS server (CN domains, direct). Also used for resolv.conf bootstrap.";
      };

      foreign = mkOption {
        type = types.attrsOf types.anything;
        default = {
          type = "https";
          tag = "dns-foreign";
          server = "1.1.1.1";
          path = "/dns-query";
        };
        description = "Foreign DNS server (non-CN, via proxy).";
      };

      detour = mkOption {
        type = types.str;
        default = cfg.finalOutbound;
        defaultText = lib.literalExpression "config.osf.sing-box-gateway.finalOutbound";
        description = "Outbound detour for foreign DNS queries.";
      };

      extraServers = mkOption {
        type = types.listOf (types.attrsOf types.anything);
        default = [ ];
        description = "Extra DNS servers (mesh, overlay, k8s).";
      };

      extraRules = mkOption {
        type = types.listOf (types.attrsOf types.anything);
        default = [ ];
        description = "Extra DNS rules.";
      };

      cacheCapacity = mkOption {
        type = types.nullOr types.int;
        default = 4096;
        description = "DNS cache capacity.";
      };

      reverseMapping = mkOption {
        type = types.bool;
        default = true;
        description = "Enable DNS reverse mapping.";
      };

      listen = mkOption {
        type = types.bool;
        default = true;
        description = "Listen on :53 to serve DNS to LAN clients.";
      };

      listenAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "DNS listen bind address.";
      };

      listenPort = mkOption {
        type = types.port;
        default = 53;
        description = "DNS listen port.";
      };

      setSystemResolver = mkOption {
        type = types.bool;
        default = true;
        description = "Point system resolver at sing-box's :53 and manage resolv.conf lifecycle.";
      };
    };

    # ── Geo ruleset ─────────────────────────────────────────────────
    geoCnPath = mkOption {
      type = types.path;
      default = pkgs.callPackage ../../packages/geo-cn-ruleset.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../../packages/geo-cn-ruleset.nix { }";
      description = ''
        LOCAL path to the CN geo rule-set (sing-box source format). Must be
        a store path so startup has zero network dependency — a remote
        rule_set hard-fails sing-box start when cache.db lacks the tag,
        crash-looping the gateway's LAN DNS. Default is nix-pinned from the
        geo-rules R2 cache; bump via packages/update-geo-cn.sh.
      '';
    };

    # ── Clash API ───────────────────────────────────────────────────
    clashApi = {
      enable = mkEnableOption "Clash API + metacubexd dashboard";

      port = mkOption {
        type = types.port;
        default = 9090;
        description = "Clash API listen port.";
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Clash API bind address.";
      };

      secretFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to file containing the Clash API secret.";
      };
    };

    # ── Forwarded LAN traffic ──────────────────────────────────────
    sourceSubnets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Source CIDRs for forwarded traffic. Gates auto_redirect firewall INPUT rules.";
    };

    # ── Lifecycle ──────────────────────────────────────────────────
    afterServices = mkOption {
      type = types.listOf types.str;
      default = [ "network-online.target" ];
      description = "systemd After= dependencies.";
    };

    conflictServices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "systemd Conflicts= (mutually exclusive services).";
    };

    configPostProcess = mkOption {
      type = types.functionTo (types.attrsOf types.anything);
      default = c: c;
      description = "Post-process the generated config attrset.";
    };

    extraGeneratorArgs = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = ''
        Extra arguments passed to singbox-config-generator. Maps directly to
        generator params: route_direct_cidrs, route_direct_domains,
        route_direct_process_name, find_process, interface_name, etc.
      '';
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
      description = "sing-box log level.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = clashOn -> cfg.clashApi.secretFile != null;
        message = "osf.sing-box-gateway: clashApi.secretFile must be set when Clash API is enabled.";
      }
    ];

    environment.systemPackages = [ singBoxPkg ];

    # ── sing-box service ───────────────────────────────────────────
    systemd.services.${cfg.serviceName} = {
      description = "sing-box transparent proxy gateway (TUN auto_redirect)";
      after = cfg.afterServices ++ lib.optional clashOn "sops-nix.service";
      wants = lib.filter (s: lib.hasSuffix ".target" s) cfg.afterServices;
      wantedBy = [ "multi-user.target" ];
      conflicts = cfg.conflictServices;

      serviceConfig = {
        ExecStart = "${singBoxPkg}/bin/sing-box run -c ${configPath}";
        ExecStartPre = [
          "+${dnsBootstrapScript}"
        ]
        ++ lib.optional clashOn secretInjectionScript
        ++ [ "${singBoxPkg}/bin/sing-box check -c ${configPath}" ];
        ExecStopPost = "${dnsBootstrapScript}";
        Restart = "on-failure";
        RestartSec = 5;
        LimitNOFILE = 65536;
        AmbientCapabilities = capabilities;
        CapabilityBoundingSet = capabilities;
        StateDirectory = cfg.serviceName;
      }
      // lib.optionalAttrs clashOn {
        RuntimeDirectory = cfg.serviceName;
      }
      // lib.optionalAttrs cfg.dns.setSystemResolver {
        ExecStartPost = "+${dnsRestoreScript}";
      };
    };

    # ── Networking ──────────────────────────────────────────────────
    networking = lib.mkMerge [
      (lib.mkIf cfg.dns.setSystemResolver {
        nameservers = mkForce [ "127.0.0.1" ];
      })
      {
        firewall.checkReversePath = mkForce "loose";
      }
      (lib.mkIf hasSubnets {
        firewall.extraInputRules = ''
          ip saddr { ${lib.concatStringsSep ", " cfg.sourceSubnets} } ct status dnat accept comment "sing-box auto_redirect: forwarded LAN clients"
        '';
      })
    ];

    # metacubexd dashboard assets
    systemd.tmpfiles.rules = lib.mkIf clashOn [
      "L+ ${dashboardDir} - - - - ${dashboardPkg}"
    ];
  };
}
