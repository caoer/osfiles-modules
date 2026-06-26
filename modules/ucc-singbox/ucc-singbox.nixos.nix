# modules/ucc-singbox/ucc-singbox.nixos.nix — per-UCC-profile sing-box routing.
#
# Fetches a complete sing-box config from the mesh-network API at activation
# time. The API resolves the token's profile→server mappings, builds
# process_path_regex route rules, and returns a ready-to-run config.
#
# Three modes:
#   tun-us        — direct: UCC profile processes proxy, everything else DIRECT.
#                   For hosts with good local egress (ZT's own boxes).
#   tun-us-strict — direct + LAN proxy: UCC exits direct, everything else through
#                   a fixed LAN proxy. Structural kill-switch. Default for guest
#                   VMs / semi-managed hosts. Requires lanProxy config.
#   tun-cn        — relay: full geo routing + UCC relay chain (CN / censored).
#
# The module post-processes the API response to inject include_uid (scopes the
# TUN to a single system user), auto_redirect (Linux), and optionally a LAN
# proxy outbound (tun-us-strict).
#
# Usage (direct, US host):
#   osf.uccSingbox = {
#     enable = true;
#     user = "caoer115";
#   };
#
# Usage (strict, guest VM with LAN proxy):
#   osf.uccSingbox = {
#     enable = true;
#     user = "xiaobai";
#     preset = "tun-us-strict";
#     bootstrapGateway = "172.19.0.1";
#     lanProxy = {
#       server = "172.19.0.43";
#       port = 23050;
#       method = "2022-blake3-aes-256-gcm";
#       passwordSecret = "sing-box-ss-password";
#     };
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
  runtimeConfig = "/run/${serviceName}/config.json";

  userHome = config.users.users.${cfg.user}.home;

  isStrict = cfg.preset == "tun-us-strict";
  # tun-us-strict uses the same API preset as tun-us — the "strict" part
  # (LAN proxy + final route change) is handled in post-processing.
  apiPreset = if isStrict then "tun-us" else cfg.preset;

  # --- Fetch + post-process script ---
  fetchScript = pkgs.writeShellScript "${serviceName}-fetch" ''
    set -eu
    umask 077

    token="$(cat "${config.sops.secrets.${cfg.tokenSecret}.path}")"
    if [ -z "$token" ]; then
      echo "${serviceName}: empty token" >&2
      exit 1
    fi

    target_uid="$(${pkgs.coreutils}/bin/id -u ${cfg.user})"

    url="${cfg.apiUrl}/config/$token?type=singbox&features=${lib.concatStringsSep "," cfg.features}&preset=${apiPreset}&port=-1&env.HOME=${userHome}"
    ${lib.optionalString (cfg.extraQueryParams != "") ''url="$url&${cfg.extraQueryParams}"''}

    ${lib.optionalString (cfg.bootstrapGateway != "") ''
      # Kill-switch bootstrap: temporarily add a default route to reach the API.
      echo "${serviceName}: adding bootstrap route via ${cfg.bootstrapGateway}"
      ${pkgs.iproute2}/bin/ip route add default via ${cfg.bootstrapGateway} metric 9999 2>/dev/null || true
      trap '${pkgs.iproute2}/bin/ip route del default via ${cfg.bootstrapGateway} metric 9999 2>/dev/null || true' EXIT
    ''}

    echo "${serviceName}: fetching config from API (preset=${apiPreset})"
    raw=$(${pkgs.curl}/bin/curl -fsSL --max-time 30 "$url")

    # Validate it's JSON before processing
    echo "$raw" | ${pkgs.jq}/bin/jq empty 2>/dev/null || {
      echo "${serviceName}: API returned invalid JSON" >&2
      echo "$raw" | head -5 >&2
      exit 1
    }

    # Post-process step 1: TUN fields
    # - Root (uid 0): omit include_uid so TUN captures ALL users' traffic
    # - Non-root: add include_uid to scope TUN to that user only
    # - Enable auto_redirect on Linux (always recommended per upstream docs)
    if [ "$target_uid" = "0" ]; then
      echo "$raw" | ${pkgs.jq}/bin/jq '
        (.inbounds // [] | .[] | select(.type == "tun"))
          |= (.auto_redirect = true)
      ' > ${runtimeConfig}
    else
      echo "$raw" | ${pkgs.jq}/bin/jq --argjson uid "$target_uid" '
        (.inbounds // [] | .[] | select(.type == "tun"))
          |= (.include_uid = [$uid] | .auto_redirect = true)
      ' > ${runtimeConfig}
    fi

    ${lib.optionalString isStrict ''
      # Post-process step 2 (tun-us-strict): inject LAN proxy outbound + change final route.
      # UCC exits still go direct; everything else → LAN proxy.
      lan_pw="$(cat "${config.sops.secrets.${cfg.lanProxy.passwordSecret}.path}")"
      ${pkgs.jq}/bin/jq --arg pw "$lan_pw" '
        .outbounds += [{
          "type": "shadowsocks",
          "tag": "lan-proxy",
          "server": "${cfg.lanProxy.server}",
          "server_port": ${toString cfg.lanProxy.port},
          "method": "${cfg.lanProxy.method}",
          "password": $pw,
          "udp_over_tcp": true
        }]
        | .route.final = "lan-proxy"
      ' ${runtimeConfig} > ${runtimeConfig}.tmp && mv ${runtimeConfig}.tmp ${runtimeConfig}
    ''}

    ${singboxPkg}/bin/sing-box check -c ${runtimeConfig}

    profiles=$(${pkgs.jq}/bin/jq '[.route.rules // [] | .[] | select(.process_path_regex)] | length' ${runtimeConfig})
    echo "${serviceName}: ready — $profiles profile route(s), uid=$target_uid${lib.optionalString isStrict ", strict mode (lan-proxy → ${cfg.lanProxy.server}:${toString cfg.lanProxy.port})"}"
  '';

in
{
  options.osf.uccSingbox = {
    enable = lib.mkEnableOption "per-UCC-profile sing-box routing (mesh-network API)";

    user = lib.mkOption {
      type = lib.types.str;
      description = "System user whose UCC profile processes are routed (resolved to UID for TUN include_uid).";
    };

    instanceName = lib.mkOption {
      type = lib.types.str;
      default = "ucc";
      description = "Instance name. Service = sing-box-ucc-<name>. Change for multi-instance on same host.";
    };

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://network.sui.pics";
      description = "mesh-network API base URL.";
    };

    tokenSecret = lib.mkOption {
      type = lib.types.str;
      default = "ucc-singbox-token";
      description = "sops secret name holding the mesh-network API token (e.g. zt-w7wm3p2kma4ddw6p).";
    };

    preset = lib.mkOption {
      type = lib.types.str;
      default = "tun-us";
      description = ''
        Routing mode:
          tun-us        — direct: UCC-only proxy, rest DIRECT (ZT's own boxes)
          tun-us-strict — direct + LAN proxy: UCC direct, rest through lanProxy (guest VMs)
          tun-cn        — relay: full geo routing + UCC relay chain (CN hosts)
      '';
    };

    features = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ucc"
        "ipv6"
        "emoji"
      ];
      description = "API feature flags (CSV). 'ucc' is required; add 'ipv6', 'emoji' as needed.";
    };

    lanProxy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          server = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = "172.19.0.43";
            description = "LAN proxy server IP.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 23050;
            description = "LAN proxy server port.";
          };
          method = lib.mkOption {
            type = lib.types.str;
            default = "2022-blake3-aes-256-gcm";
            description = "Shadowsocks encryption method.";
          };
          passwordSecret = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "sops secret name holding the Shadowsocks password.";
          };
        };
      };
      default = { };
      description = ''
        LAN proxy config for tun-us-strict mode. Required when preset = "tun-us-strict".
        Non-UCC traffic routes through this fixed proxy. UCC exits still go direct.
      '';
    };

    bootstrapGateway = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "172.19.0.1";
      description = ''
        LAN gateway IP for bootstrapping the API fetch on kill-switch hosts.
        When set, the fetch script temporarily adds a default route via this
        gateway, fetches the config, then removes it.
      '';
    };

    extraQueryParams = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "default-relay=us-dmit-ss-23061";
      description = "Extra query parameters appended to the API URL.";
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
        assertion = !isStrict || (cfg.lanProxy ? server && cfg.lanProxy.server != "");
        message = "osf.uccSingbox: preset 'tun-us-strict' requires lanProxy.server to be configured.";
      }
    ];

    environment.systemPackages = [ singboxPkg ];

    sops.secrets = {
      ${cfg.tokenSecret} = { };
    } // lib.optionalAttrs isStrict {
      ${cfg.lanProxy.passwordSecret} = { };
    };

    systemd.services.${serviceName} = {
      description = "sing-box UCC profile routing for ${cfg.user} (${cfg.preset})";
      after = [
        "network-online.target"
        "sops-nix.service"
      ];
      wants = [
        "network-online.target"
        "sops-nix.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStartPre = fetchScript;
        ExecStart = "${singboxPkg}/bin/sing-box -D /var/lib/${serviceName} run -c ${runtimeConfig}";
        # No CapabilityBoundingSet — process_path_regex routing needs broad
        # /proc access (readlink exe, list fd, netlink INET_DIAG) that fails
        # under restrictive capability sets.
        Restart = "on-failure";
        RestartSec = 10;
        RuntimeDirectory = serviceName;
        StateDirectory = serviceName;
        LimitNOFILE = 65536;
      };
    };
  };
}
