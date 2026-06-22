# modules/sing-box-client/sing-box-client.nixos.nix — UID-scoped sing-box TUN proxy.
#
# Transparent proxy for a single user via TUN + `include_uid`. All other users
# and system services keep native networking. If sing-box dies, the target user's
# egress blackholes (table 2022 routes become undeliverable) while root/SSH stays
# alive — same kill-switch as coscene-vm/cos-ucc.
#
# Two modes:
#   direct       — plain SS-2022 outbounds (US / non-censored networks)
#   shadowtls    — ShadowTLS v3 wrapped SS-2022 (CN / censored networks)
#
# Secrets are never in the nix store. A render script (ExecStartPre) injects
# passwords + UID via jq into /run/sing-box-<instance>/config.json (tmpfs).
#
# Usage (direct, US server):
#   osf.sing-box-client = {
#     enable = true;
#     user = "xiaobai";
#     instanceName = "xb";
#     servers = {
#       dmit  = { server = "64.186.233.167";  port = 23050; };
#       dmit2 = { server = "64.186.236.100";  port = 23050; };
#     };
#   };
#
# Usage (ShadowTLS, CN server):
#   osf.sing-box-client = {
#     enable = true;
#     user = "zt";
#     instanceName = "zt";
#     shadowtls.enable = true;
#     servers = {
#       bwg   = { server = "144.34.230.170"; };
#       dmit  = { server = "2605:52c0:2:11b4:be24:11ff:fef8:c09"; };
#       dmit2 = { server = "2605:52c0:2:347d:be24:11ff:fe74:adfa"; };
#     };
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.sing-box-client;
  singboxPkg = pkgs.callPackage ../../packages/sing-box.nix { };

  inst = cfg.instanceName;
  serviceName = "sing-box-${inst}";
  tunName = "tun-${inst}";
  runtimeConfig = "/run/${serviceName}/config.json";

  # Server option type.
  serverOpts = lib.types.submodule {
    options = {
      server = lib.mkOption {
        type = lib.types.str;
        description = "Server IP or hostname.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = if cfg.shadowtls.enable then cfg.shadowtls.port else 23050;
        defaultText = lib.literalExpression "shadowtls port or 23050";
        description = "Server port (SS direct port, or ShadowTLS listen port).";
      };
    };
  };

  # --- Outbound builders ---

  # Direct SS outbound (password injected at activation).
  mkDirectOutbound = name: srv: {
    type = "shadowsocks";
    tag = "ss-${name}";
    inherit (srv) server;
    server_port = srv.port;
    method = cfg.ssMethod;
    password = ""; # injected at activation
    udp_over_tcp = true;
    multiplex = {
      enabled = true;
      protocol = "h2mux";
      max_connections = 4;
      min_streams = 4;
      padding = true;
    };
  };

  # ShadowTLS v3 + inner SS pair (passwords injected at activation).
  mkStlsPair = name: srv: [
    {
      type = "shadowtls";
      tag = "stls-${name}";
      inherit (srv) server;
      server_port = srv.port;
      version = 3;
      password = ""; # injected at activation
      tls = {
        enabled = true;
        server_name = cfg.shadowtls.sni;
      };
    }
    {
      type = "shadowsocks";
      tag = "ss-${name}";
      method = cfg.shadowtls.ssMethod;
      password = ""; # injected at activation
      detour = "stls-${name}";
    }
  ];

  serverNames = lib.attrNames cfg.servers;
  ssOutboundTags = map (n: "ss-${n}") serverNames;

  outbounds =
    if cfg.shadowtls.enable then
      (lib.concatMap (n: mkStlsPair n cfg.servers.${n}) serverNames)
    else
      (map (n: mkDirectOutbound n cfg.servers.${n}) serverNames);

  # --- Config template (no secrets) ---
  configTemplate = {
    log.level = cfg.logLevel;
    dns = {
      servers = [
        {
          tag = "proxy-dns";
          type = "tls";
          server = cfg.dnsServer;
          detour = "auto";
        }
      ];
      final = "proxy-dns";
    };
    inbounds = [
      {
        type = "tun";
        tag = "tun-in";
        interface_name = tunName;
        address = [ cfg.tunAddress ];
        auto_route = true;
        strict_route = false; # coexist with EasyTier/tailscale
        stack = "mixed";
        include_uid = [ ]; # filled at activation
      }
      {
        type = "mixed";
        tag = "${inst}-proxy";
        listen = "127.0.0.1";
        listen_port = cfg.mixedPort;
      }
    ];
    outbounds = outbounds ++ [
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
      rules = [
        { protocol = "dns"; action = "hijack-dns"; }
        { action = "sniff"; }
        {
          ip_cidr = cfg.directCidrs;
          outbound = "direct";
          action = "route";
        }
      ] ++ cfg.extraRouteRules;
      final = "auto";
    };
  };

  templateJson = builtins.toJSON configTemplate;
  templateFile = pkgs.writeText "${serviceName}-template.json" templateJson;

  # --- Secret file paths ---
  ssPasswordFile = config.sops.secrets.${cfg.ssPasswordSecret}.path;
  stlsPasswordFile =
    if cfg.shadowtls.enable then
      config.sops.secrets.${cfg.shadowtls.passwordSecret}.path
    else
      "/dev/null";

  # --- Render script: inject UID + passwords at activation ---
  renderScript =
    let
      jqFilter =
        if cfg.shadowtls.enable then
          ''
            (.outbounds[] | select(.type == "shadowsocks")).password = $ss_pw
            | (.outbounds[] | select(.type == "shadowtls")).password = $stls_pw
            | (.inbounds[] | select(.tag == "tun-in")).include_uid = [$uid]
          ''
        else
          ''
            (.outbounds[] | select(.type == "shadowsocks")).password = $ss_pw
            | (.inbounds[] | select(.tag == "tun-in")).include_uid = [$uid]
          '';
      secretChecks =
        if cfg.shadowtls.enable then ''
          for f in "${ssPasswordFile}" "${stlsPasswordFile}"; do
            if [ ! -s "$f" ]; then
              echo "${serviceName}: missing secret $f" >&2
              exit 1
            fi
          done
          stls_pw="$(cat "${stlsPasswordFile}")"
        '' else ''
          if [ ! -s "${ssPasswordFile}" ]; then
            echo "${serviceName}: missing secret ${ssPasswordFile}" >&2
            exit 1
          fi
          stls_pw=""
        '';
    in
    pkgs.writeShellScript "${serviceName}-render" ''
      set -eu
      umask 077
      ${secretChecks}
      ss_pw="$(cat "${ssPasswordFile}")"
      target_uid="$(${pkgs.coreutils}/bin/id -u ${cfg.user})"
      ${pkgs.jq}/bin/jq \
        --arg ss_pw "$ss_pw" --arg stls_pw "$stls_pw" --argjson uid "$target_uid" \
        '${jqFilter}' \
        ${templateFile} > ${runtimeConfig}
      ${singboxPkg}/bin/sing-box check -c ${runtimeConfig}
    '';

in
{
  options.osf.sing-box-client = {
    enable = lib.mkEnableOption "UID-scoped sing-box TUN proxy client";

    user = lib.mkOption {
      type = lib.types.str;
      description = "System user whose traffic is captured by the TUN (resolved to UID at activation).";
    };

    instanceName = lib.mkOption {
      type = lib.types.str;
      description = "Short name for the instance. Service = sing-box-<name>, TUN = tun-<name>.";
    };

    servers = lib.mkOption {
      type = lib.types.attrsOf serverOpts;
      description = "Proxy server definitions. Keys become outbound tags (ss-<key>).";
    };

    ssMethod = lib.mkOption {
      type = lib.types.str;
      default = "2022-blake3-aes-256-gcm";
      description = "Shadowsocks encryption method.";
    };

    ssPasswordSecret = lib.mkOption {
      type = lib.types.str;
      default = "sing-box-ss-password";
      description = "sops secret name for the SS password.";
    };

    shadowtls = {
      enable = lib.mkEnableOption "ShadowTLS v3 wrapping around SS outbounds (for censored networks)";

      passwordSecret = lib.mkOption {
        type = lib.types.str;
        default = "sing-box-stls-password";
        description = "sops secret name for the ShadowTLS v3 password.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 23061;
        description = "ShadowTLS listen port on servers.";
      };

      sni = lib.mkOption {
        type = lib.types.str;
        default = "swcdn.apple.com";
        description = "TLS SNI for the ShadowTLS handshake.";
      };

      ssMethod = lib.mkOption {
        type = lib.types.str;
        default = "2022-blake3-aes-256-gcm";
        description = "SS method for the inner ShadowTLS connection.";
      };
    };

    mixedPort = lib.mkOption {
      type = lib.types.port;
      default = 7891;
      description = "Local mixed HTTP+SOCKS5 proxy port (127.0.0.1).";
    };

    tunAddress = lib.mkOption {
      type = lib.types.str;
      default = "172.19.8.1/30";
      description = "TUN interface address (must not collide with host networking).";
    };

    dnsServer = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
      description = "DNS-over-TLS server for proxied resolution.";
    };

    directCidrs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "127.0.0.0/8"
      ];
      description = "CIDRs routed direct (bypassing proxy). Covers private/mesh/loopback.";
    };

    extraRouteRules = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Extra sing-box route rules appended after the direct CIDR rule.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "trace" "debug" "info" "warn" "error" "fatal" "panic" ];
      default = "info";
      description = "sing-box log level.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.servers != { };
        message = "osf.sing-box-client: at least one server must be defined.";
      }
    ];

    environment.systemPackages = [ singboxPkg ];

    sops.secrets = lib.mkMerge [
      { ${cfg.ssPasswordSecret} = { }; }
      (lib.mkIf cfg.shadowtls.enable {
        ${cfg.shadowtls.passwordSecret} = { };
      })
    ];

    systemd.services.${serviceName} = {
      description = "sing-box UID-scoped TUN proxy for ${cfg.user} (${
        if cfg.shadowtls.enable then "ShadowTLS v3" else "SS-2022"
      } urltest: ${lib.concatStringsSep "+" serverNames})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStartPre = renderScript;
        ExecStart = "${singboxPkg}/bin/sing-box -D /var/lib/${serviceName} run -c ${runtimeConfig}";
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
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
