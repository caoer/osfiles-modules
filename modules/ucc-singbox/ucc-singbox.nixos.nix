# modules/ucc-singbox/ucc-singbox.nixos.nix — per-UCC-profile sing-box routing.
#
# Fetches a complete sing-box config from the mesh-network API. The API
# resolves the token's profile→server mappings, builds process_path_regex
# route rules, and returns a ready-to-run config. The host renders it, checks
# it and installs it in the unit's StateDirectory with the raw answer beside
# it. The router fetches on its first start after boot and starts on the
# stored config when that fetch fails; afterwards each revision the mesh
# Worker pushes down the -fleet socket runs the -update, which restarts the
# router only when the raw answer changed.
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
  singboxPkg = cfg.package;

  inst = cfg.instanceName;
  serviceName = "sing-box-ucc-${inst}";

  # The installed config, the raw API answer it was rendered from, and the
  # renderer that rendered it. Kept across reboots: a start whose fetch fails
  # runs on what is here.
  stateDir = "/var/lib/${serviceName}";
  liveConfig = "${stateDir}/config.json";

  userHome = config.users.users.${cfg.user}.home;

  isStrict = cfg.preset == "tun-us-strict";
  # tun-us-strict uses the same API preset as tun-us — the "strict" part
  # (LAN proxy + final route change) is handled in post-processing.
  apiPreset = if isStrict then "tun-us" else cfg.preset;

  fleetUrl = "${
    lib.replaceStrings [ "https://" "http://" ] [ "wss://" "ws://" ] cfg.apiUrl
  }/fleet/ws";

  # --- Fetch: the raw API answer to $1 ---
  fetchScript = pkgs.writeShellScript "${serviceName}-fetch" ''
    set -eu
    umask 077
    out="$1"

    token="$(cat "${config.sops.secrets.${cfg.tokenSecret}.path}")"
    if [ -z "$token" ]; then
      echo "${serviceName}: empty token" >&2
      exit 1
    fi

    url="${cfg.apiUrl}/config/$token?type=singbox&features=${lib.concatStringsSep "," cfg.features}&preset=${apiPreset}&port=-1&env.HOME=${userHome}"
    ${lib.optionalString (cfg.extraQueryParams != "") ''url="$url&${cfg.extraQueryParams}"''}

    ${lib.optionalString (cfg.bootstrapGateway != "") ''
      # Kill-switch bootstrap: temporarily add a default route to reach the API.
      echo "${serviceName}: adding bootstrap route via ${cfg.bootstrapGateway}"
      ${pkgs.iproute2}/bin/ip route add default via ${cfg.bootstrapGateway} metric 9999 2>/dev/null || true
      trap '${pkgs.iproute2}/bin/ip route del default via ${cfg.bootstrapGateway} metric 9999 2>/dev/null || true' EXIT
    ''}

    echo "${serviceName}: fetching config from API (preset=${apiPreset})" >&2
    # The URL carries the token, so it reaches curl on stdin, not argv.
    printf 'url = "%s"\n' "$url" \
      | ${pkgs.curl}/bin/curl -fsSL --max-time 30 --config - -o "$out"

    ${pkgs.jq}/bin/jq empty "$out" 2>/dev/null || {
      echo "${serviceName}: API returned invalid JSON" >&2
      head -c 300 "$out" >&2
      echo >&2
      exit 1
    }
  '';

  # --- Render: raw API answer $1 → checked sing-box config $2 ---
  renderScript = pkgs.writeShellScript "${serviceName}-render" ''
    set -eu
    umask 077
    raw="$1"
    out="$2"

    target_uid="$(${pkgs.coreutils}/bin/id -u ${cfg.user})"
    extra_uids="$(${pkgs.coreutils}/bin/printf '%s\n' ${lib.concatMapStringsSep " " (u: "\"$(${pkgs.coreutils}/bin/id -u ${u})\"") cfg.extraUsers})"

    # Post-process step 1: TUN fields
    # - Root (uid 0): omit include_uid so TUN captures ALL users' traffic
    # - Non-root: add include_uid to scope TUN to that user only
    # - Enable auto_redirect on Linux (always recommended per upstream docs)
    # - Exclude this host's own addresses from auto_route / auto_redirect, and
    #   reject them in route.rules. sing-tun binds the auto_redirect listener
    #   on IP:0_0_0_0 at a random port with no config knob (redirect_linux.go
    #   picks netip.IPv4Unspecified), so on a host with a public IP that
    #   listener is internet-reachable. A connection that did not arrive
    #   through the REDIRECT rule carries no conntrack original-dst, so
    #   sing-box reads the socket's own address as the destination — dest
    #   <own-ip>:<redirect-port>. A `bypass` action hands that back to the
    #   listener through `direct`, a self-feeding hairpin that pegs CPU;
    #   `reject` closes the connection instead. The redirectGuard unit below
    #   drops the seed traffic at the packet layer — except on lo, which it
    #   admits: a local probe of the port (or the dual-stack listener reached
    #   on ::1) reads as dest 127.0.0.1:<redirect-port> and seeds the same
    #   hairpin (xu-lax: 16k self-connections/min, 3 cores). Loopback is
    #   rejected as well: nothing legitimate reaches the router with a
    #   loopback destination — the output REDIRECT chain returns for the
    #   local address set, and loopback never routes through the tun.
    # - Exclude docker/br-/veth from auto_route so published containers
    #   don't enter the TUN.
    # - tun-us: force strict_route=false. API default true blackholes
    #   return paths on dual-homed / docker web hosts.
    host_cidrs="$(${pkgs.iproute2}/bin/ip -4 -o addr show \
      | ${pkgs.gawk}/bin/awk '
          $2 == "lo" { next }
          $2 ~ /^tun/ { next }
          $4 ~ /^127\./ { next }
          {
            split($4, a, "/")
            if (a[1] != "") print a[1] "/32"
          }
        ')"
    docker_ifaces="$(${pkgs.iproute2}/bin/ip -o link show \
      | ${pkgs.gawk}/bin/awk -F': ' '{print $2}' \
      | ${pkgs.gnused}/bin/sed 's/@.*//' \
      | ${pkgs.gnugrep}/bin/grep -E '^(docker[0-9]*|br-|veth)' || true)"

    ${pkgs.jq}/bin/jq \
      --argjson uid "$target_uid" \
      --arg extra_uids "$extra_uids" \
      --arg cidrs "$host_cidrs" \
      --argjson ex_route ${lib.escapeShellArg (builtins.toJSON cfg.routeExcludeAddress)} \
      --arg ifaces "$docker_ifaces" \
      --argjson force_loose ${if isStrict then "false" else "true"} \
      '
        ($cidrs | split("\n") | map(select(length > 0))) as $ex_addr
        | ($extra_uids | split("\n") | map(select(length > 0) | tonumber)) as $more_uids
        | ($ifaces | split("\n") | map(select(length > 0))) as $ex_if
        | (.inbounds // [] | .[] | select(.type == "tun")) |= (
            .auto_redirect = true
            | if $uid == 0 then del(.include_uid) else .include_uid = ([$uid] + $more_uids) end
            | if $force_loose then .strict_route = false else . end
            | .route_exclude_address = (((.route_exclude_address // []) + $ex_addr + $ex_route) | unique)
            | if ($ex_if | length) > 0
              then .exclude_interface = (((.exclude_interface // []) + $ex_if) | unique)
              else . end
          )
        | .route.rules = (
            [
              { action: "sniff" },
              { action: "hijack-dns", protocol: "dns" },
              { action: "reject", ip_cidr: ($ex_addr + ["127.0.0.0/8", "::1/128"]) }
            ]
            + ((.route.rules // []) | map(select(
                .action != "sniff" and .action != "hijack-dns"
              )))
          )
      ' "$raw" > "$out"
    echo "${serviceName}: tun exclude addrs=$(echo "$host_cidrs" | tr '\n' ' ')"

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
      ' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    ''}

    ${lib.concatMapStrings (hook: ''
      ${hook} "$out"
    '') cfg.postFetch}
    ${singboxPkg}/bin/sing-box check -c "$out"

    profiles=$(${pkgs.jq}/bin/jq '[.route.rules // [] | .[] | select(.process_path_regex)] | length' "$out")
    echo "${serviceName}: rendered — $profiles profile route(s), uid=$target_uid${lib.optionalString isStrict ", strict mode (lan-proxy → ${cfg.lanProxy.server}:${toString cfg.lanProxy.port})"}"
  '';

  # --- Config: `start` (the main unit's ExecStartPre) and `update [result]` ---
  #
  # start  — on the first start after boot (or with nothing stored) fetch and
  #          render; a failed fetch renders the stored fetch, a failed render
  #          keeps the stored config. A later start renders only when the
  #          renderer changed (a rebuild), from the stored fetch, offline.
  # update — fetch; when the raw answer equals the stored one and the renderer
  #          is the same, report `unchanged` and touch nothing. Otherwise
  #          render, `sing-box check`, install, restart the router, report
  #          `applied`. Any failure reports `failed <one line>`, exits non-zero
  #          and leaves the installed config as it was.
  #
  # The compare is raw fetch to raw fetch, so what the renderer and the
  # postFetch hooks add (this boot's addresses, a host's rewrite) never reads
  # as a change. The result word goes to the file named by $2 (the fleet
  # socket's answer).
  configScript = pkgs.writeShellScript "${serviceName}-config" ''
    set -eu
    umask 077
    mode="''${1:?usage: start | update [result-file]}"
    result="''${2:-}"
    state=${stateDir}
    renderer=${renderScript}
    # What rendered the installed config; a rebuild that changes it re-renders.
    stamp="$renderer"

    say() { echo "${serviceName}: $*" >&2; }
    report() { if [ -n "$result" ]; then printf '%s\n' "$*" > "$result"; fi; }
    fail() { say "$*"; report "failed $*"; exit 1; }

    mkdir -p -m 0700 "$state"
    exec 9>"$state/.lock"
    ${pkgs.util-linux}/bin/flock 9
    work="$(mktemp -d "$state/.next.XXXXXX")"
    trap 'rm -rf "$work"' EXIT

    # Each step runs as its own script (set -e holds inside it); its stderr
    # reaches the journal, and its last line is the failure's one line.
    fetch() {
      if ${fetchScript} "$work/raw.json" 2>"$work/err"; then
        cat "$work/err" >&2
      else
        cat "$work/err" >&2
        return 1
      fi
    }
    render() {
      if "$renderer" "$work/raw.json" "$work/config.json" >&2 2>"$work/err"; then
        cat "$work/err" >&2
      else
        cat "$work/err" >&2
        return 1
      fi
    }
    lastline() { tail -n 1 "$work/err" | tr -d '\r'; }
    # Config first, raw and the renderer stamp last: an install cut short
    # leaves a stale stamp, which the next update reads as a change.
    install_candidate() {
      printf '%s\n' "$stamp" > "$work/render.id"
      mv -f "$work/config.json" "$state/config.json"
      mv -f "$work/raw.json" "$state/raw.json"
      mv -f "$work/render.id" "$state/render.id"
    }
    same_renderer() { [ "$(cat "$state/render.id" 2>/dev/null || true)" = "$stamp" ]; }

    case "$mode" in
      start)
        boot="$(cat /proc/sys/kernel/random/boot_id)"
        have_raw=0
        if [ -s "$state/raw.json" ] && [ -s "$state/config.json" ] \
          && [ "$(cat "$state/boot_id" 2>/dev/null || true)" = "$boot" ]; then
          if ! same_renderer; then
            cp "$state/raw.json" "$work/raw.json"
            have_raw=1
          fi
        elif fetch; then
          have_raw=1
        elif [ -s "$state/raw.json" ]; then
          say "fetch failed — rendering the stored fetch"
          cp "$state/raw.json" "$work/raw.json"
          have_raw=1
        fi
        if [ "$have_raw" = 1 ]; then
          if render; then
            install_candidate
          elif [ -s "$state/config.json" ]; then
            say "render failed ($(lastline)) — starting on the stored config"
          else
            fail "render failed and no config is stored: $(lastline)"
          fi
        elif [ -s "$state/config.json" ]; then
          say "fetch failed — starting on the stored config"
        else
          fail "fetch failed and no config is stored: $(lastline)"
        fi
        printf '%s\n' "$boot" > "$state/boot_id"
        say "starting on $(sha256sum "$state/config.json" | cut -c1-12)"
        ;;
      update)
        fetch || fail "fetch: $(lastline)"
        if [ -s "$state/config.json" ] && same_renderer \
          && ${pkgs.diffutils}/bin/cmp -s "$work/raw.json" "$state/raw.json"; then
          say "config unchanged"
          report unchanged
          exit 0
        fi
        render || fail "render: $(lastline)"
        install_candidate
        # The router's start takes the same lock.
        ${pkgs.util-linux}/bin/flock -u 9
        say "config changed — restarting ${serviceName}"
        ${pkgs.systemd}/bin/systemctl restart ${serviceName}.service \
          || fail "installed, but ${serviceName} failed to restart"
        report applied
        ;;
      *)
        fail "unknown mode $mode"
        ;;
    esac
  '';

  # --- Fleet socket client (plan § 3.4), run by websocat on the socket ---
  # stdout is the socket, one frame per line; logs go to stderr. The first
  # frame carries the token — read from the secret on stdin, so it is never on
  # an argv or in the URL. Each {"rev": N} runs one update and answers
  # {"applied": N}, {"unchanged": N} or {"failed": N, "error": "<line>"}.
  fleetClient = pkgs.writeShellScript "${serviceName}-fleet-client" ''
    set -u
    jq=${pkgs.jq}/bin/jq
    say() { echo "${serviceName}-fleet: $*" >&2; }

    $jq -Rsc --arg host "$(cat /proc/sys/kernel/hostname)" \
      '{token: rtrimstr("\n"), host: $host}' \
      < "${config.sops.secrets.${cfg.tokenSecret}.path}" || exit 1

    res="$(mktemp)"
    trap 'rm -f "$res"' EXIT
    while IFS= read -r frame; do
      rev="$(printf '%s\n' "$frame" | $jq -r '.rev | numbers' 2>/dev/null || true)"
      if [ -z "$rev" ]; then
        say "ignored a frame without a rev"
        continue
      fi
      : > "$res"
      ${configScript} update "$res" >&2 || true
      read -r word detail < "$res" || word=""
      case "$word" in
        applied | unchanged)
          say "$word rev $rev"
          $jq -nc --arg w "$word" --argjson n "$rev" '{($w): $n}'
          ;;
        *)
          detail="''${detail:-the update ended without a result}"
          say "failed rev $rev: $detail"
          $jq -nc --argjson n "$rev" --arg e "$detail" '{failed: $n, error: $e}'
          ;;
      esac
    done
    say "socket closed"
  '';

  guardTable = "${serviceName}-guard";

  # sing-box picks the auto_redirect port at start and binds it on IP:0_0_0_0.
  # Only two paths legitimately reach that listener: an output-chain REDIRECT
  # (rewritten to IP:127_0_0_1, arrives on lo) and a prerouting REDIRECT (arrives
  # NAT'd, so conntrack carries the dnat status). Everything else on that port
  # is an unsolicited connection to the host's public IP — drop it, so the
  # transparent-proxy listener is not an open port on the internet.
  redirectGuard = pkgs.writeShellScript "${serviceName}-redirect-guard" ''
    set -u
    nft=${pkgs.nftables}/bin/nft

    port=""
    for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
      port="$($nft list table inet sing-box 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -oE 'redirect to :[0-9]+' \
        | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+' \
        | ${pkgs.coreutils}/bin/head -1)"
      [ -n "$port" ] && break
      ${pkgs.coreutils}/bin/sleep 1
    done

    if [ -z "$port" ]; then
      echo "${serviceName}: no auto_redirect port in table inet sing-box — guard not installed" >&2
      exit 0
    fi

    $nft delete table inet ${guardTable} 2>/dev/null
    $nft -f - <<EOF
    table inet ${guardTable} {
      chain input {
        type filter hook input priority filter - 5; policy accept;
        iifname "lo" return
        meta l4proto != tcp return
        tcp dport $port ct status dnat return
        tcp dport $port counter drop
      }
    }
    EOF
    echo "${serviceName}: redirect-port guard installed — tcp/$port drops non-redirected inbound"
  '';

  # Residual / conflicting TUN state:
  # - A crash or SIGKILL leaves priority-90xx rules + route table 2022 (auto_route)
  #   pointing at a dead tun — blackhole risk on next start.
  # - The pre-Nix installer (~/.local/ucc-sing-box, sudo ./bin/sing-box run -C .)
  #   claims the same TEST-NET addresses (192.0.2.0/30) and table 2022, so the
  #   managed unit dies with: "set routes: add route 0: file exists".
  # Stop legacy installer processes, flush auto_route residue, drop orphan tuns.
  tunCleanup = pkgs.writeShellScript "${serviceName}-tun-cleanup" ''
    set +e
    ip=${pkgs.iproute2}/bin/ip

    ${pkgs.nftables}/bin/nft delete table inet ${guardTable} 2>/dev/null

    for pid in /proc/[0-9]*; do
      p=''${pid#/proc/}
      cwd=$(${pkgs.coreutils}/bin/readlink "$pid/cwd" 2>/dev/null || true)
      case "$cwd" in
        */.local/ucc-sing-box|*/.local/ucc-sing-box/*)
          echo "${serviceName}: stopping legacy installer pid=$p cwd=$cwd"
          ${pkgs.util-linux}/bin/kill "$p" 2>/dev/null
          ;;
      esac
    done
    ${pkgs.coreutils}/bin/sleep 0.5

    for fam in -4 -6; do
      $ip $fam rule show 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F: '$1 ~ /^90[0-9][0-9]$/ {print $1}' \
        | while read -r prio; do
            $ip $fam rule del priority "$prio" 2>/dev/null
          done
      $ip $fam route flush table 2022 2>/dev/null
    done

    for dev in $($ip -o link show 2>/dev/null \
      | ${pkgs.gawk}/bin/awk -F': ' '{print $2}' \
      | ${pkgs.gnused}/bin/sed 's/@.*//'); do
      case "$dev" in
        tun*)
          if $ip -4 addr show "$dev" 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -q '192\.0\.2\.'; then
            echo "${serviceName}: deleting residual $dev (TEST-NET auto_route)"
            $ip link del "$dev" 2>/dev/null
          fi
          ;;
      esac
    done
    exit 0
  '';

in
{
  options.osf.uccSingbox = {
    enable = lib.mkEnableOption "per-UCC-profile sing-box routing (mesh-network API)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/sing-box.nix { };
      description = "sing-box package to use.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "System user whose UCC profile processes are routed (resolved to UID for TUN include_uid).";
    };

    extraUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "cosops" ];
      description = ''
        Further system users whose UCC profile processes ride the same TUN
        (appended to include_uid). The profile route rules match
        `.local/share/ucc/profiles/<profile>/` under any home, so one instance
        serves every agent user on the host. Ignored when `user` is root.
      '';
    };

    routeExcludeAddress = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.60.0.0/14" ];
      description = ''
        CIDRs the TUN leaves to the next policy rule (route_exclude_address):
        a destination another uid-scoped tun on the host owns at a lower rule
        priority than this instance's 90xx rules.
      '';
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

    postFetch = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Executables run in order on each rendered candidate, before
        `sing-box check`, with the candidate's path as their first argument;
        each may rewrite the file in place. A non-zero exit refuses the
        candidate and the installed config stays. Updates compare raw API
        answers, so a hook's rewrite never reads as a change.
      '';
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

    # What sing-box writes back through its tun — the answers to the DNS
    # queries hijack-dns took off the routed users — arrives on that tun
    # from the upstream resolver's address. The nixos-fw rpfilter chain's fib
    # lookup for that source lands in main (eth0, not the tun) and drops it;
    # TCP is unaffected because auto_redirect carries it over nftables. Cached
    # names still answer, so the symptom is "some names resolve, new ones time
    # out". The kernel names the tun (the first free tunN — EasyTier may hold
    # tun0), so the exemption keys on the address the profile gives it
    # (TEST-NET-1, the same one tunCleanup keys on), not on a name.
    networking.firewall.extraReversePathFilterRules = ''
      ip daddr 192.0.2.0/30 accept
      ip6 daddr fdfe:dcba:9876::/126 accept
    '';

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
        # Order: clear residue / kill legacy installer, then the config
        # (fetched on the first start after boot, else the stored one).
        ExecStartPre = [
          "+${tunCleanup}"
          "${configScript} start"
        ];
        ExecStart = "${singboxPkg}/bin/sing-box -D ${stateDir} run -c ${liveConfig}";
        # Fence the auto_redirect listener once sing-box has published its port.
        ExecStartPost = "+${redirectGuard}";
        # Unconditional teardown so crash residue cannot poison the next start.
        ExecStopPost = "+${tunCleanup}";
        # No CapabilityBoundingSet — process_path_regex routing needs broad
        # /proc access (readlink exe, list fd, netlink INET_DIAG) that fails
        # under restrictive capability sets.
        Restart = "on-failure";
        RestartSec = 10;
        StateDirectory = serviceName;
        StateDirectoryMode = "0700";
        LimitNOFILE = 65536;
      };
    };

    # By hand: systemctl start <serviceName>-update. The fleet socket below
    # runs the same update on every pushed revision.
    systemd.services."${serviceName}-update" = {
      description = "Refetch the UCC sing-box config for ${cfg.user}; restart ${serviceName} when it changed";
      after = [
        "network-online.target"
        "sops-nix.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${configScript} update";
      };
    };

    # The mesh Worker pushes each registry revision down this socket; the
    # client applies it and answers (plan § 3.4). No timer: a host that is
    # offline catches up on the revision it is sent at reconnect.
    systemd.services."${serviceName}-fleet" = {
      description = "Fleet socket for ${serviceName}: apply each pushed registry revision";
      after = [
        "network-online.target"
        "sops-nix.service"
        "${serviceName}.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${pkgs.websocat}/bin/websocat --text --linemode-strip-newlines --exit-on-eof --ping-interval 30 --ping-timeout 90 ${fleetUrl} exec:${fleetClient}";
        Restart = "always";
        RestartSec = 10;
        RestartSteps = 5;
        RestartMaxDelaySec = 300;
      };
    };
  };
}
