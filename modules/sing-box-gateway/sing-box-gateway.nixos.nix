# modules/sing-box-gateway/sing-box-gateway.nixos.nix — Transparent proxy gateway via sing-box.
#
# Single TUN inbound (auto_route + auto_redirect) captures BOTH:
#   * gateway's own outbound traffic, and
#   * forwarded traffic from LAN/VM clients that use gateway as default route.
#
# DNS: split DNS built into sing-box — CN domains → AliDNS (direct), foreign
# domains → Cloudflare DoH (via proxy). DNS inbound on :53 serves LAN clients.
#
# Config generation delegated to singbox-config-generator (../lib/).
# Host-specific outbound groups, route rules, and DNS config are passed through
# NixOS options and merged by the generator.
#
# Optional iptables TPROXY mode: when sourceSubnets is set, a companion
# oneshot service installs mangle/TPROXY rules for forwarded LAN traffic.
#
# Usage:
#   osf.sing-box-gateway = {
#     enable = true;
#     outboundGroups = { ... };      # host-specific proxy exits
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
  inherit (lib) mkEnableOption mkOption mkIf mkForce types;

  cfg = config.osf.sing-box-gateway;

  gen = (import ../../lib/singbox-config-generator.nix) { inherit lib; };
  mkService = (import ../../lib/mkSingBoxService.nix) { inherit lib; };

  singBoxPkg = cfg.package;
  dashboardPkg = cfg.dashboardPackage;

  clashOn = cfg.clashApi.enable;
  dashboardDir = "${cfg.stateDirectory}/dashboard";
  runtimeConfigPath = "/run/${cfg.serviceName}/config.json";

  # ── Generate sing-box config via singbox-config-generator ──────────
  generated = gen ({
    inherit (cfg)
      outboundGroups
      finalOutbound
      ;

    shadowtlsDefaults = cfg.shadowtlsDefaults;

    extraOutbounds = cfg.extraOutbounds;

    tun_address = cfg.tunAddresses;
    interface_name = cfg.tunInterface;
    route_exclude_address = cfg.routeExcludeAddresses;
    exclude_interface = cfg.excludeInterfaces;

    route_direct_cidrs = cfg.directCidrs;
    route_direct_domains = cfg.directDomains;
    route_direct_process_name = cfg.directProcessNames;

    extraRouteRules = cfg.extraRouteRules;

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
    find_process = cfg.findProcess;
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
  } // cfg.extraGeneratorArgs);

  # Post-process: configPostProcess hook (e.g. store_dns in cache_file).
  finalConfig = cfg.configPostProcess generated.config;

  configTemplate = pkgs.writeText "${cfg.serviceName}.json" (builtins.toJSON finalConfig);

  # ── Secret injection (when Clash API is enabled) ──────────────────
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

  # ── DNS fallback (restore direct DNS when service stops) ──────────
  dnsFallbackScript = pkgs.writeShellScript "${cfg.serviceName}-dns-fallback" ''
    printf 'nameserver ${cfg.dns.domestic.server}\n' > /etc/resolv.conf
  '';
  restoreDnsCmd = "${pkgs.openresolv}/sbin/resolvconf -u";

  # ── iptables TPROXY rules ─────────────────────────────────────────
  tproxyOn = cfg.sourceSubnets != [ ];
  tproxyPort = cfg.tproxyPort;
  fwmark = cfg.tproxyFwmark;
  routeTable = cfg.tproxyRouteTable;

  iptables = "${pkgs.iptables}/bin/iptables";
  ip = "${pkgs.iproute2}/bin/ip";

  # Destinations excluded from tproxy — locally routable, no proxy needed.
  tproxyExcludeDests = cfg.tproxyExcludeDests ++ cfg.sourceSubnets;

  # iptables chain name limit: 28 chars. Use a short fixed name.
  chainName = "SB_GW_TPROXY";

  setupScript = pkgs.writeShellScript "${cfg.serviceName}-tproxy-setup" ''
    set -e
    ${ip} rule add fwmark ${toString fwmark} lookup ${toString routeTable} 2>/dev/null || true
    ${ip} route replace local default dev lo table ${toString routeTable}

    ${iptables} -t mangle -N ${chainName} 2>/dev/null || ${iptables} -t mangle -F ${chainName}

    ${lib.concatMapStrings (cidr: ''
      ${iptables} -t mangle -A ${chainName} -d ${cidr} -j RETURN
    '') tproxyExcludeDests}

    ${lib.optionalString (!cfg.dns.listen) ''
      ${iptables} -t mangle -A ${chainName} -p udp --dport 53 -j RETURN
      ${iptables} -t mangle -A ${chainName} -p tcp --dport 53 -j RETURN
    ''}

    ${iptables} -t mangle -A ${chainName} -p tcp -j TPROXY \
      --on-port ${toString tproxyPort} --tproxy-mark ${toString fwmark}/${toString fwmark}
    ${iptables} -t mangle -A ${chainName} -p udp -j TPROXY \
      --on-port ${toString tproxyPort} --tproxy-mark ${toString fwmark}/${toString fwmark}

    ${lib.concatMapStrings (subnet: ''
      ${iptables} -t mangle -A PREROUTING -s ${subnet} -j ${chainName}
    '') cfg.sourceSubnets}

    ${pkgs.nftables}/bin/nft insert rule inet nixos-fw rpfilter meta mark ${toString fwmark} accept 2>/dev/null || true
  '';

  teardownScript = pkgs.writeShellScript "${cfg.serviceName}-tproxy-teardown" ''
    ${pkgs.nftables}/bin/nft delete rule inet nixos-fw rpfilter handle \
      $(${pkgs.nftables}/bin/nft -a list chain inet nixos-fw rpfilter 2>/dev/null \
        | grep "meta mark.*0x0000000${toString fwmark} accept" | awk '{print $NF}') 2>/dev/null || true
    ${lib.concatMapStrings (subnet: ''
      ${iptables} -t mangle -D PREROUTING -s ${subnet} -j ${chainName} 2>/dev/null || true
    '') cfg.sourceSubnets}
    ${iptables} -t mangle -F ${chainName} 2>/dev/null || true
    ${iptables} -t mangle -X ${chainName} 2>/dev/null || true
    ${ip} rule del fwmark ${toString fwmark} lookup ${toString routeTable} 2>/dev/null || true
    ${ip} route del local default dev lo table ${toString routeTable} 2>/dev/null || true
  '';

in
{
  options.osf.sing-box-gateway = {
    enable = mkEnableOption "sing-box transparent proxy gateway (TUN + split DNS)";

    # ── Package ─────────────────────────────────────────────────────
    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../packages/sing-box.nix { };
      description = "sing-box package to use. Override with a fork (e.g. sing-box-sor) as needed.";
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
      description = "systemd service name. Also used for state/runtime directories.";
    };

    stateDirectory = mkOption {
      type = types.str;
      default = "/var/lib/${cfg.serviceName}";
      description = "Persistent state directory (cache.db, dashboard).";
    };

    # ── TUN configuration ───────────────────────────────────────────
    tunInterface = mkOption {
      type = types.str;
      default = "tun-gw";
      description = "TUN interface name.";
    };

    tunAddresses = mkOption {
      type = types.listOf types.str;
      default = [ "172.19.0.1/30" ];
      description = "TUN interface addresses (IPv4 and/or IPv6).";
    };

    routeExcludeAddresses = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "IPs excluded from TUN at the kernel level (DNS resolvers, mesh relay).";
    };

    excludeInterfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Network interfaces excluded from TUN routing.";
    };

    # ── Outbounds ───────────────────────────────────────────────────
    outboundGroups = mkOption {
      type = types.attrsOf (types.submodule {
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
      });
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
      description = "Default ShadowTLS parameters for outbound groups that use `shadowtls = true`.";
    };

    finalOutbound = mkOption {
      type = types.str;
      default = "proxy-select";
      description = "Tag of the outbound used as route.final (catch-all exit).";
    };

    # ── Route rules ─────────────────────────────────────────────────
    directCidrs = mkOption {
      type = types.listOf types.str;
      default = [
        "10.144.0.0/16"
        "10.42.0.0/16"
        "10.43.0.0/16"
        "100.64.0.0/10"
      ];
      description = "CIDRs routed direct (mesh, overlay, tailscale).";
    };

    directDomains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Domains routed direct.";
    };

    directProcessNames = mkOption {
      type = types.listOf types.str;
      default = [
        "easytier-core"
        "easytier-cli"
        "iperf"
        "iperf3"
      ];
      description = "Process names routed direct (mesh VPN, benchmarks).";
    };

    findProcess = mkOption {
      type = types.bool;
      default = false;
      description = "Enable process name matching in route rules.";
    };

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
        description = "Domestic DNS server (CN domains, direct).";
      };

      foreign = mkOption {
        type = types.attrsOf types.anything;
        default = {
          type = "https";
          tag = "dns-foreign";
          server = "1.1.1.1";
          path = "/dns-query";
        };
        description = "Foreign DNS server (non-CN domains, via proxy).";
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
        description = "DNS cache capacity. Null uses sing-box default.";
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
        description = "Point system resolver at sing-box DNS listener (127.0.0.1).";
      };
    };

    # ── Geo ruleset ─────────────────────────────────────────────────
    geoCnPath = mkOption {
      type = types.path;
      default = ../../data/geo-cn.json;
      description = "Path to the CN geo ruleset (local, source format).";
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
        example = "/run/secrets/clash-api-secret";
        description = "Path to file containing the Clash API secret. Injected at runtime.";
      };
    };

    # ── TPROXY (iptables rules for forwarded LAN traffic) ───────────
    sourceSubnets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Source CIDRs whose forwarded traffic gets transparently proxied via iptables TPROXY. Empty disables TPROXY rules.";
    };

    tproxyPort = mkOption {
      type = types.port;
      default = 12345;
      description = "TPROXY inbound listen port.";
    };

    tproxyFwmark = mkOption {
      type = types.int;
      default = 1;
      description = "fwmark for TPROXY policy routing.";
    };

    tproxyRouteTable = mkOption {
      type = types.int;
      default = 100;
      description = "Policy routing table number for TPROXY.";
    };

    tproxyExcludeDests = mkOption {
      type = types.listOf types.str;
      default = [
        "127.0.0.0/8"
        "10.0.0.0/8"
        "100.64.0.0/10"
        "172.16.0.0/12"
        "224.0.0.0/4"
        "255.255.255.255/32"
      ];
      description = "Destination CIDRs excluded from TPROXY (loopback, mesh, overlay, multicast). sourceSubnets auto-appended.";
    };

    # ── Lifecycle hooks ─────────────────────────────────────────────
    afterServices = mkOption {
      type = types.listOf types.str;
      default = [ "network-online.target" ];
      description = "systemd After= dependencies.";
    };

    conflictServices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "systemd Conflicts= (services that must stop when this starts).";
    };

    configPostProcess = mkOption {
      type = types.functionTo (types.attrsOf types.anything);
      default = c: c;
      description = "Post-process the generated config attrset before serialization.";
    };

    extraGeneratorArgs = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "Extra arguments passed directly to singbox-config-generator.";
    };

    logLevel = mkOption {
      type = types.enum [ "trace" "debug" "info" "warn" "error" "fatal" "panic" ];
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

    environment.systemPackages = [ singBoxPkg ]
      ++ lib.optionals tproxyOn [ pkgs.iptables pkgs.iproute2 ];

    # ── Main sing-box service ───────────────────────────────────────
    systemd.services =
      lib.recursiveUpdate
        (mkService {
          name = cfg.serviceName;
          package = singBoxPkg;
          configPath = if clashOn then runtimeConfigPath else configTemplate;
          description = "sing-box transparent proxy gateway (TUN auto_redirect)";
          afterServices = cfg.afterServices
            ++ lib.optional clashOn "sops-nix.service";
          stateDirectory = cfg.serviceName;
          runtimeDirectory = if clashOn then cfg.serviceName else null;
          check = !clashOn;
          extraStartPre = if clashOn then secretInjectionScript else null;
          extraStopPost = "${dnsFallbackScript}";
          capabilities = [
            "CAP_NET_BIND_SERVICE"
            "CAP_NET_ADMIN"
            "CAP_NET_RAW"
          ];
        })
        {
          ${cfg.serviceName} = {
            conflicts = cfg.conflictServices;
          }
          // lib.optionalAttrs cfg.dns.setSystemResolver {
            serviceConfig.ExecStartPost = restoreDnsCmd;
          };
        }
      # ── TPROXY iptables rules (companion oneshot) ─────────────────
      // lib.optionalAttrs tproxyOn {
        "${cfg.serviceName}-rules" = {
          description = "tproxy iptables rules for ${cfg.serviceName}";
          after = [ "${cfg.serviceName}.service" ];
          requires = [ "${cfg.serviceName}.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "+${setupScript}";
            ExecStop = "+${teardownScript}";
          };
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
      (lib.mkIf tproxyOn {
        firewall.extraInputRules =
          let
            lanSubnets = cfg.sourceSubnets;
          in
          lib.optionalString (lanSubnets != [ ]) ''
            ip saddr { ${lib.concatStringsSep ", " lanSubnets} } ct status dnat accept comment "sing-box auto_redirect: forwarded LAN clients"
          ''
          + ''
            meta mark ${toString fwmark} accept
          '';
      })
    ];

    # metacubexd dashboard assets.
    systemd.tmpfiles.rules = lib.mkIf clashOn [
      "L+ ${dashboardDir} - - - - ${dashboardPkg}"
    ];
  };
}
