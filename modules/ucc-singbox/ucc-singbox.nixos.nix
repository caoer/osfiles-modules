# modules/ucc-singbox/ucc-singbox.nixos.nix — per-UCC-profile sing-box routing.
#
# Routes each UCC profile's processes through a dedicated exit server via
# sing-box process_path_regex rules. Two modes:
#
#   direct  — ShadowTLS+SS outbounds connect to exit servers directly
#             (US / non-censored networks)
#   relay   — ShadowTLS+SS outbounds chain through a consumer-provided relay
#             detour (CN / censored networks, e.g. a local gateway hop)
#
# Consumer provides the profile-to-server mapping as Nix attrsets (sourced
# from mesh-network's TOML configs, or inline). Shared credentials (SS
# password, ShadowTLS password) are sops secrets — all exits in the GCP
# fleet share one key pair.
#
# Multi-host: the same user can deploy this on multiple servers with
# different profile subsets and modes. Instance naming prevents collision.
#
# Usage (direct, US host):
#   osf.uccSingbox = {
#     enable = true;
#     user = "caoer115";
#     profiles = {
#       does_bannock_6u = { server = "34.145.249.21"; };
#       monk0foreleg    = { server = "136.118.217.14"; };
#     };
#   };
#
# Usage (relay, CN host):
#   osf.uccSingbox = {
#     enable = true;
#     user = "caoer115";
#     mode = "relay";
#     relay.outbounds = [
#       { type = "shadowsocks"; tag = "gw"; server = "192.168.92.1"; ... }
#     ];
#     relay.detourTag = "gw";
#     profiles = { ... };
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.uccSingbox;
  singboxPkg = pkgs.callPackage ../../packages/sing-box.nix { };

  inst = cfg.instanceName;
  serviceName = "sing-box-ucc-${inst}";
  tunName = "tun-ucc-${inst}";
  runtimeConfig = "/run/${serviceName}/config.json";

  profileNames = lib.attrNames cfg.profiles;
  isRelay = cfg.mode == "relay";

  # Home directory of the target user (for process_path_regex).
  userHome = config.users.users.${cfg.user}.home;

  # --- Profile option type ---
  profileOpts = lib.types.submodule {
    options = {
      server = lib.mkOption {
        type = lib.types.str;
        description = "Exit server IP or hostname for this profile.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = cfg.exitDefaults.port;
        defaultText = lib.literalExpression "osf.uccSingbox.exitDefaults.port";
        description = "ShadowTLS listen port on the exit server.";
      };
      ssMethod = lib.mkOption {
        type = lib.types.str;
        default = cfg.exitDefaults.ssMethod;
        defaultText = lib.literalExpression "osf.uccSingbox.exitDefaults.ssMethod";
        description = "SS encryption method override for this profile.";
      };
    };
  };

  # --- Outbound builders ---

  # ShadowTLS v3 wrapper → detours to relay (relay mode) or connects directly.
  mkStlsOutbound = name: prof: {
    type = "shadowtls";
    tag = "${name}-shadowtls-${toString prof.port}";
    server = prof.server;
    server_port = prof.port;
    version = cfg.exitDefaults.shadowtls.version;
    password = ""; # injected at activation
    tls = {
      enabled = true;
      server_name = cfg.exitDefaults.shadowtls.sni;
      utls = {
        enabled = true;
        fingerprint = "chrome";
      };
    };
  } // lib.optionalAttrs isRelay {
    detour = cfg.relay.detourTag;
  };

  # Inner SS outbound — detours through its ShadowTLS wrapper.
  mkSsOutbound = name: prof: {
    type = "shadowsocks";
    tag = "ucc-${name}";
    server = prof.server;
    server_port = prof.port;
    method = prof.ssMethod;
    password = ""; # injected at activation
    udp_over_tcp = true;
    multiplex = cfg.exitDefaults.multiplex;
    detour = "${name}-shadowtls-${toString prof.port}";
  };

  # All outbounds: ShadowTLS + SS pair per profile.
  profileOutbounds = lib.concatMap (
    name:
    let
      prof = cfg.profiles.${name};
    in
    [
      (mkStlsOutbound name prof)
      (mkSsOutbound name prof)
    ]
  ) profileNames;

  ssOutboundTags = map (n: "ucc-${n}") profileNames;

  # --- Route rules: process_path_regex per profile ---
  profileRouteRules = map (name: {
    action = "route";
    outbound = "ucc-${name}";
    process_path_regex = [
      "${lib.escape [ "." ] userHome}/\\.local/share/ucc/profiles/${lib.escape [ "." ] name}"
    ];
  }) profileNames;

  # --- DNS ---
  dnsConfig = {
    servers = [
      {
        type = "udp";
        tag = "local-dns";
        server = cfg.dnsServer;
        server_port = 53;
      }
      {
        tag = "fakeip";
        type = "fakeip";
        inet4_range = "198.18.0.0/16";
        inet6_range = "fc00::/18";
      }
    ];
    rules = [
      {
        query_type = [ "A" "AAAA" ];
        server = "fakeip";
      }
      {
        ip_accept_any = true;
        server = "local-dns";
      }
    ];
    strategy = "prefer_ipv4";
  };

  # --- Full config template ---
  configTemplate = {
    log = {
      level = cfg.logLevel;
      timestamp = true;
    };
    dns = dnsConfig;
    inbounds = [
      {
        type = "mixed";
        tag = "mixed-in";
        listen = "127.0.0.1";
        listen_port = cfg.mixedPort;
      }
      {
        type = "tun";
        tag = "tun-in";
        interface_name = tunName;
        address = [ cfg.tunAddress "fd00::1/64" ];
        auto_route = true;
        auto_redirect = true;
        strict_route = true;
        route_exclude_address = [ "127.0.0.0/8" ];
        include_uid = [ ]; # filled at activation
      }
    ];
    outbounds =
      # Consumer-provided relay outbounds first (so they're available as detour targets).
      (lib.optionals isRelay cfg.relay.outbounds)
      ++ profileOutbounds
      ++ [
        {
          type = "urltest";
          tag = "auto";
          outbounds = ssOutboundTags;
          interval = "3m";
          tolerance = 50;
        }
        {
          type = "direct";
          tag = "direct";
        }
      ];
    route = {
      rules =
        [
          { action = "sniff"; }
          { protocol = "dns"; action = "hijack-dns"; }
        ]
        ++ profileRouteRules
        ++ cfg.extraRouteRules
        ++ [
          {
            ip_cidr = cfg.directCidrs;
            outbound = "direct";
            action = "route";
          }
        ];
      final = cfg.defaultOutbound;
      default_domain_resolver = "local-dns";
      auto_detect_interface = true;
    };
  };

  templateJson = builtins.toJSON configTemplate;
  templateFile = pkgs.writeText "${serviceName}-template.json" templateJson;

  # --- Secret file paths ---
  ssPasswordFile = config.sops.secrets.${cfg.exitDefaults.ssPasswordSecret}.path;
  stlsPasswordFile = config.sops.secrets.${cfg.exitDefaults.shadowtls.passwordSecret}.path;

  # --- Render script: inject UID + passwords at activation ---
  renderScript = pkgs.writeShellScript "${serviceName}-render" ''
    set -eu
    umask 077

    for f in "${ssPasswordFile}" "${stlsPasswordFile}"; do
      if [ ! -s "$f" ]; then
        echo "${serviceName}: missing secret $f" >&2
        exit 1
      fi
    done

    ss_pw="$(cat "${ssPasswordFile}")"
    stls_pw="$(cat "${stlsPasswordFile}")"
    target_uid="$(${pkgs.coreutils}/bin/id -u ${cfg.user})"

    ${pkgs.jq}/bin/jq \
      --arg ss_pw "$ss_pw" \
      --arg stls_pw "$stls_pw" \
      --argjson uid "$target_uid" \
      '
        (.outbounds[] | select(.type == "shadowsocks" and .tag != null and (.tag | startswith("ucc-")))).password = $ss_pw
        | (.outbounds[] | select(.type == "shadowtls")).password = $stls_pw
        | (.inbounds[] | select(.tag == "tun-in")).include_uid = [$uid]
      ' \
      ${templateFile} > ${runtimeConfig}

    ${singboxPkg}/bin/sing-box check -c ${runtimeConfig}
    echo "${serviceName}: rendered $(${pkgs.jq}/bin/jq '.route.rules | map(select(.process_path_regex)) | length' ${runtimeConfig}) profile route(s), uid=$target_uid"
  '';

in
{
  options.osf.uccSingbox = {
    enable = lib.mkEnableOption "per-UCC-profile sing-box process-path routing";

    user = lib.mkOption {
      type = lib.types.str;
      description = "System user whose UCC profile processes are routed (resolved to UID for TUN include_uid).";
    };

    instanceName = lib.mkOption {
      type = lib.types.str;
      default = "ucc";
      description = "Instance name. Service = sing-box-ucc-<name>, TUN = tun-ucc-<name>. Change for multi-instance.";
    };

    mode = lib.mkOption {
      type = lib.types.enum [
        "direct"
        "relay"
      ];
      default = "direct";
      description = ''
        direct — ShadowTLS+SS connects to exit servers directly (US / non-censored).
        relay  — ShadowTLS+SS chains through relay.detourTag (CN / censored).
      '';
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf profileOpts;
      default = { };
      description = ''
        UCC profile → exit server mapping. Key = profile name (matches
        ~/.local/share/ucc/profiles/<key>/). Consumer data — sourced from
        mesh-network TOML or inline.
      '';
    };

    # --- Exit server defaults (shared across profiles) ---
    exitDefaults = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 443;
        description = "Default ShadowTLS listen port on exit servers.";
      };

      ssMethod = lib.mkOption {
        type = lib.types.str;
        default = "2022-blake3-aes-128-gcm";
        description = "Default SS encryption method for exit servers.";
      };

      ssPasswordSecret = lib.mkOption {
        type = lib.types.str;
        default = "ucc-singbox-ss-password";
        description = "sops secret name for the shared SS password across all exits.";
      };

      shadowtls = {
        version = lib.mkOption {
          type = lib.types.int;
          default = 3;
          description = "ShadowTLS protocol version.";
        };

        passwordSecret = lib.mkOption {
          type = lib.types.str;
          default = "ucc-singbox-stls-password";
          description = "sops secret name for the shared ShadowTLS password.";
        };

        sni = lib.mkOption {
          type = lib.types.str;
          default = "swcdn.apple.com";
          description = "TLS SNI for ShadowTLS handshake.";
        };
      };

      multiplex = lib.mkOption {
        type = lib.types.attrs;
        default = {
          enabled = true;
          protocol = "smux";
          max_connections = 8;
          min_streams = 2;
          padding = true;
        };
        description = "Default multiplex config for SS outbounds.";
      };
    };

    # --- Relay config (mode = "relay") ---
    relay = {
      detourTag = lib.mkOption {
        type = lib.types.str;
        default = "relay";
        description = "Outbound tag that ShadowTLS detours through in relay mode.";
      };

      outbounds = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = ''
          Consumer-provided relay outbound definitions (sing-box JSON).
          Must include at least one outbound whose tag matches detourTag.
          Example: a local SS gateway, a DMIT relay hop, etc.
        '';
      };
    };

    # --- Routing ---
    defaultOutbound = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "Outbound for traffic not matching any profile rule. 'auto' = urltest across all profile exits.";
    };

    directCidrs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "127.0.0.0/8"
      ];
      description = "CIDRs routed direct (bypassing proxy).";
    };

    extraRouteRules = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Extra sing-box route rules inserted after profile rules, before direct CIDRs.";
    };

    # --- Network ---
    mixedPort = lib.mkOption {
      type = lib.types.port;
      default = 6780;
      description = "Local mixed HTTP+SOCKS5 proxy port (127.0.0.1).";
    };

    tunAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.9.96.1/30";
      description = "TUN interface address.";
    };

    dnsServer = lib.mkOption {
      type = lib.types.str;
      default = "223.5.5.5";
      description = "Upstream DNS server (UDP). Default: Aliyun (reachable from CN + US).";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
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

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.profiles != { };
        message = "osf.uccSingbox: at least one profile must be defined.";
      }
      {
        assertion = !isRelay || cfg.relay.outbounds != [ ];
        message = "osf.uccSingbox: relay mode requires at least one relay outbound.";
      }
    ];

    environment.systemPackages = [ singboxPkg ];

    sops.secrets = {
      ${cfg.exitDefaults.ssPasswordSecret} = { };
      ${cfg.exitDefaults.shadowtls.passwordSecret} = { };
    };

    systemd.services.${serviceName} = {
      description = "sing-box UCC profile routing for ${cfg.user} (${cfg.mode}, ${toString (lib.length profileNames)} profiles)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStartPre = renderScript;
        ExecStart = "${singboxPkg}/bin/sing-box -D /var/lib/${serviceName} run -c ${runtimeConfig}";
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = serviceName;
        StateDirectory = serviceName;
        LimitNOFILE = 65536;
      };

      restartTriggers = [ (builtins.hashString "sha256" templateJson) ];
    };
  };
}
