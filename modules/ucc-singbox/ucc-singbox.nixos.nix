# modules/ucc-singbox/ucc-singbox.nixos.nix — per-UCC-profile sing-box routing.
#
# Fetches a complete sing-box config from the mesh-network API at activation
# time. The API resolves the token's profile→server mappings, builds
# process_path_regex route rules, and returns a ready-to-run config.
#
# Two modes (map to API presets):
#   direct  — tun-us preset: TUN captures traffic, only UCC profile processes
#             proxy, everything else DIRECT (US / non-censored networks)
#   relay   — consumer-specified preset with relay chain (CN / censored)
#
# The module post-processes the API response to inject include_uid (scopes the
# TUN to a single system user) and optionally patches platform-specific fields
# (auto_redirect for Linux).
#
# Multi-host: same token deploys on multiple servers — the API serves the same
# profile set, each host just runs its own sing-box instance.
#
# Usage (direct, US host):
#   osf.uccSingbox = {
#     enable = true;
#     user = "caoer115";
#   };
#
# Usage (relay, CN host):
#   osf.uccSingbox = {
#     enable = true;
#     user = "caoer115";
#     preset = "tun-cn";
#     extraQueryParams = "default-relay=us-dmit-ss-23061";
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

  # --- Fetch + post-process script ---
  #
  # 1. Fetch config from mesh-network API (token from sops, HOME from config)
  # 2. Inject include_uid to scope TUN to the target user
  # 3. Enable auto_redirect on Linux (the API ships false for portability)
  # 4. Validate with sing-box check
  fetchScript = pkgs.writeShellScript "${serviceName}-fetch" ''
    set -eu
    umask 077

    token="$(cat "${config.sops.secrets.${cfg.tokenSecret}.path}")"
    if [ -z "$token" ]; then
      echo "${serviceName}: empty token" >&2
      exit 1
    fi

    target_uid="$(${pkgs.coreutils}/bin/id -u ${cfg.user})"

    url="${cfg.apiUrl}/config/$token?type=singbox&features=ucc&preset=${cfg.preset}&env.HOME=${userHome}"
    ${lib.optionalString (cfg.extraQueryParams != "") ''url="$url&${cfg.extraQueryParams}"''}

    echo "${serviceName}: fetching config from API (preset=${cfg.preset})"
    raw=$(${pkgs.curl}/bin/curl -fsSL --max-time 30 "$url")

    # Validate it's JSON before processing
    echo "$raw" | ${pkgs.jq}/bin/jq empty 2>/dev/null || {
      echo "${serviceName}: API returned invalid JSON" >&2
      echo "$raw" | head -5 >&2
      exit 1
    }

    # Post-process:
    # - Add include_uid to TUN inbound (scope to target user)
    # - Enable auto_redirect on Linux TUN
    echo "$raw" | ${pkgs.jq}/bin/jq --argjson uid "$target_uid" '
      (.inbounds // [] | .[] | select(.type == "tun"))
        |= (.include_uid = [$uid] | .auto_redirect = true)
    ' > ${runtimeConfig}

    ${singboxPkg}/bin/sing-box check -c ${runtimeConfig}

    profiles=$(${pkgs.jq}/bin/jq '[.route.rules // [] | .[] | select(.process_path_regex)] | length' ${runtimeConfig})
    echo "${serviceName}: ready — $profiles profile route(s), uid=$target_uid"
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
        API preset name. Determines routing topology:
          tun-us       — direct: TUN, UCC-only proxy, rest DIRECT (US hosts)
          tun-cn       — relay: TUN, full geo routing + UCC relay chain (CN hosts)
          ucc-minimal  — mixed inbound only, no TUN (lightweight)
      '';
    };

    extraQueryParams = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "default-relay=us-dmit-ss-23061";
      description = "Extra query parameters appended to the API URL (e.g. default-relay for CN presets).";
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
      description = "sing-box log level (patched into fetched config).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ singboxPkg ];

    sops.secrets.${cfg.tokenSecret} = { };

    systemd.services.${serviceName} = {
      description = "sing-box UCC profile routing for ${cfg.user} (API: ${cfg.preset})";
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
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_BIND_SERVICE"
        ];
        Restart = "on-failure";
        RestartSec = 10;
        RuntimeDirectory = serviceName;
        StateDirectory = serviceName;
        LimitNOFILE = 65536;
      };
    };
  };
}
