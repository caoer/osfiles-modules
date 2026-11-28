# modules/ucc-singbox/ucc-singbox.nixos.nix — per-UCC-profile sing-box routing.
#
# Fetches a complete sing-box config from the mesh-network API. The API
# resolves the token's profile→server mappings, builds process_path_regex
# route rules, and returns a ready-to-run config. The host renders it, checks
# it and installs it in the unit's StateDirectory with the raw answer beside
# it. The router fetches on its first start after boot and starts on the
# stored config when that fetch fails; afterwards each revision the mesh
# Worker pushes down the -fleet socket runs the -update, which restarts the
# router only when the raw answer changed, and puts the previous config back
# when the restart fails or the router's egress check gets worse. `fleet =
# false` leaves the socket out, and the stored config stays until -update
# runs or the next boot.
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
# TUN to a single system user), auto_redirect off, optionally a LAN proxy
# outbound (tun-us-strict), and the rules that keep a flow no registry row
# claimed off Anthropic and OpenAI from the host's own address: a process
# lookup miss, ucc-codex's node, a profile with no row
# (./anthropic-failclosed.jq; with failClosed off, ./failclosed-hold.jq).
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

  # The blocks sing-box's ip_is_private matches (sing N.IsPublicAddr: private,
  # link-local, multicast), which the API answer routes direct ahead of every
  # profile rule. auto_route leaves them out of the tun, so the kernel routes
  # them as if no tun were there: a routed user's replies and forwarded flows
  # to a host-local subnet (docker, k3s, VM and collector sim links, the mesh)
  # reach that subnet, whenever it comes up. Without auto_redirect, auto_route
  # sends every routed packet to the tun by uid, replies of the user's own
  # listeners included, and the tun stack drops what it did not open.
  privateBlocks = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
    "224.0.0.0/4"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
  ];

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
    # - auto_redirect off, whatever the API answer says. The process search
    #   finds a flow's socket by the tuple sing-box sees, and auto_redirect
    #   rewrites that tuple: (1) it REDIRECTs every TCP flow to one listener,
    #   and Linux connect() reuses a local port across different
    #   destinations, so two such flows collide on the listener's reply
    #   tuple and conntrack remaps the second one's source port to a port no
    #   socket holds; (2) its marks 0x2023-0x2025 all carry bit 0x2000, the
    #   CNI portmap masquerade mark (k3s), so a connected UDP socket reaches
    #   sing-box with the tun's address as its source. Either way the lookup
    #   misses and the fail-closed rule refuses a profile's own flow. Plain
    #   auto_route puts the routed users' sockets on the tun at connect time,
    #   so sing-box sees each socket's own tuple.
    # - Exclude this host's own addresses and the private blocks
    #   (privateBlocks) from auto_route, and reject the own addresses and
    #   loopback in route.rules: nothing legitimate reaches the router with
    #   such a destination, and `direct` would hand it back to the host
    #   itself.
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
      --argjson ex_route ${lib.escapeShellArg (builtins.toJSON (privateBlocks ++ cfg.routeExcludeAddress))} \
      --arg ifaces "$docker_ifaces" \
      --argjson force_loose ${if isStrict then "false" else "true"} \
      '
        ($cidrs | split("\n") | map(select(length > 0))) as $ex_addr
        | ($extra_uids | split("\n") | map(select(length > 0) | tonumber)) as $more_uids
        | ($ifaces | split("\n") | map(select(length > 0))) as $ex_if
        | (.inbounds // [] | .[] | select(.type == "tun")) |= (
            .auto_redirect = false
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

    ${if cfg.failClosed then ''
      # Post-process step 3: a flow no registry row claimed (a process lookup
      # miss, ucc-codex's node, a profile with no row) never reaches Anthropic
      # or OpenAI from this host's own address (./anthropic-failclosed.jq).
      # Two commands, so set -e refuses the candidate when jq fails.
      ${pkgs.jq}/bin/jq -f ${./anthropic-failclosed.jq} "$out" > "$out.tmp"
      mv "$out.tmp" "$out"'' else ''
      # Post-process step 3 with failClosed off: the IPv4-only profiles' IPv6
      # guards (rule 4 of ./anthropic-failclosed.jq) — every account leaves
      # through its own exit on IPv4 and IPv6 alike, whatever the flag — then
      # the renderer-hold fail-closed (./failclosed-hold.jq): the shared
      # node's OpenAI route, Anthropic refused, any found process direct.
      ${pkgs.jq}/bin/jq --arg only v6guards -f ${./anthropic-failclosed.jq} "$out" > "$out.tmp"
      mv "$out.tmp" "$out"
      ${pkgs.jq}/bin/jq --arg home ${lib.escapeShellArg userHome} -f ${./failclosed-hold.jq} "$out" > "$out.tmp"
      mv "$out.tmp" "$out"''}
    ${singboxPkg}/bin/sing-box check -c "$out"

    profiles=$(${pkgs.jq}/bin/jq '[.route.rules // [] | .[] | select(.process_path_regex)] | length' "$out")
    echo "${serviceName}: rendered — $profiles profile route(s), uid=$target_uid${lib.optionalString isStrict ", strict mode (lan-proxy → ${cfg.lanProxy.server}:${toString cfg.lanProxy.port})"}"
  '';

  # --- Start & Update scripts (decoupled so update/classifier/hook edits never
  #     mutate ExecStartPre of the main sing-box service unit) ---
  #
  # startScript  — the main unit's ExecStartPre. On the first start after boot
  #                (or with nothing stored) fetch and render; a failed fetch
  #                renders the stored fetch, a failed render keeps the stored
  #                config. A later start renders only when the renderer changed
  #                (a rebuild), from the stored fetch, offline. References ONLY
  #                fetchScript and renderScript (never hot-reload-classify.jq
  #                or onProfileRouteChange).
  # updateScript — invoked by <serviceName>-update.service and fleetClient.
  #                Fetches raw config; when unchanged and same renderer, exits
  #                `unchanged`. Otherwise renders, checks, classifies via
  #                hot-reload-classify.jq, installs, and either hot-reloads in
  #                place (pre-reload reap -> SIGHUP -> journald confirm ->
  #                post-reload reap -> egress check, all under flock 9) or
  #                releases flock 9 and runs a deliberate systemctl restart.
  #                Any failure or egress regression rolls back under flock 9,
  #                records `rejected`, restarts the router on the previous
  #                config, reports `failed … rolled back`, and exits non-zero.
  startScript = pkgs.writeShellScript "${serviceName}-start" ''
    set -eu
    umask 077
    state=${stateDir}
    renderer=${renderScript}
    # What rendered the installed config; a rebuild that changes it re-renders.
    stamp="$renderer"

    say() { echo "${serviceName}: $*" >&2; }
    fail() { say "$*"; exit 1; }

    mkdir -p -m 0700 "$state"
    exec 9>"$state/.lock"
    ${pkgs.util-linux}/bin/flock 9
    work="$(mktemp -d "$state/.next.XXXXXX")"
    trap 'rm -rf "$work"' EXIT

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
    install_candidate() {
      printf '%s\n' "$stamp" > "$work/render.id"
      mv -f "$work/config.json" "$state/config.json"
      mv -f "$work/raw.json" "$state/raw.json"
      mv -f "$work/render.id" "$state/render.id"
    }
    same_renderer() { [ "$(cat "$state/render.id" 2>/dev/null || true)" = "$stamp" ]; }

    boot="$(cat /proc/sys/kernel/random/boot_id)"
    have_raw=0
    why="fetch failed"
    if [ -s "$state/raw.json" ] && [ -s "$state/config.json" ] \
      && [ "$(cat "$state/boot_id" 2>/dev/null || true)" = "$boot" ]; then
      if ! same_renderer; then
        cp "$state/raw.json" "$work/raw.json"
        have_raw=1
      fi
      why="fetched earlier this boot"
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
      say "$why — starting on the stored config"
    else
      fail "fetch failed and no config is stored: $(lastline)"
    fi
    printf '%s\n' "$boot" > "$state/boot_id"
    say "starting on $(sha256sum "$state/config.json" | cut -c1-12)"
  '';

  updateScript = pkgs.writeShellScript "${serviceName}-update" ''
    set -eu
    umask 077
    state=${stateDir}
    renderer=${renderScript}
    fetch_bin=${fetchScript}
    service_name=${serviceName}
    routed_user=${lib.escapeShellArg cfg.user}
    classify_jq=${./hot-reload-classify.jq}
    flock_bin=${pkgs.util-linux}/bin/flock
    cmp_bin=${pkgs.diffutils}/bin/cmp
    jq_bin=${pkgs.jq}/bin/jq
    systemctl_bin=${pkgs.systemd}/bin/systemctl
    journalctl_bin=${pkgs.systemd}/bin/journalctl
    setpriv_bin=${pkgs.util-linux}/bin/setpriv
    id_bin=${pkgs.coreutils}/bin/id
    curl_bin=${pkgs.curl}/bin/curl
    date_bin=${pkgs.coreutils}/bin/date
    awk_bin=${pkgs.gawk}/bin/awk
    grep_bin=${pkgs.gnugrep}/bin/grep
    sleep_bin=${pkgs.coreutils}/bin/sleep
    reload_confirm_ticks=30
    reload_poll_interval=0.1
    egress_reload_sleep=2
    egress_restart_sleep=3
    egress_retry_sleep=3
    reap_hooks=(${lib.concatMapStringsSep " " lib.escapeShellArg cfg.onProfileRouteChange})
    # BEGIN UCC_SINGBOX_UPDATE_SCRIPT
    if [ "''${1:-}" = "update" ]; then shift; fi
    result="''${1:-}"
    # What rendered the installed config; a rebuild that changes it re-renders.
    stamp="$renderer"

    say() { echo "''${service_name}: $*" >&2; }
    report() { if [ -n "$result" ]; then printf '%s\n' "$*" > "$result"; fi; }
    fail() { say "$*"; report "failed $*"; exit 1; }

    mkdir -p -m 0700 "$state"
    exec 9>"$state/.lock"
    lock_held=0
    acquire_lock() {
      if [ "$lock_held" = 0 ]; then
        "$flock_bin" 9
        lock_held=1
      fi
    }
    release_lock() {
      if [ "$lock_held" = 1 ]; then
        "$flock_bin" -u 9
        lock_held=0
      fi
    }
    acquire_lock
    work="$(mktemp -d "$state/.next.XXXXXX")"
    trap 'rm -rf "$work"' EXIT

    # Each step runs as its own script (set -e holds inside it); its stderr
    # reaches the journal, and its last line is the failure's one line.
    fetch() {
      if "$fetch_bin" "$work/raw.json" 2>"$work/err"; then
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

    # The egress check: "<router state> <google code> <anthropic code>", the
    # two codes from the routed user's own curl (its traffic is on the tun).
    egress() {
      as_user() {
        "$setpriv_bin" --reuid="$routed_user" --regid="$("$id_bin" -g "$routed_user")" --init-groups -- \
          "$curl_bin" -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" || true
      }
      printf '%s %s %s\n' \
        "$("$systemctl_bin" is-active "''${service_name}.service" || true)" \
        "$(as_user https://www.google.com/generate_204)" \
        "$(as_user https://api.anthropic.com/)"
    }
    # What held before ($1) and not after ($2); empty when nothing got worse.
    worse() {
      set -- $1 $2
      w=""
      if [ "''${1:-}" = active ] && [ "''${4:-}" != active ]; then w="router ''${4:-?}"; fi
      if [ "''${2:-}" = 204 ] && [ "''${5:-}" != 204 ]; then w="''${w:+$w, }google ''${5:-?}"; fi
      if [ "''${3:-}" = 000 ] && [ "''${6:-}" != 000 ]; then w="''${w:+$w, }anthropic reached (''${6:-?})"; fi
      printf '%s' "$w"
    }

    run_reap_hooks() {
      phase="$1"
      [ -n "$reap_profiles" ] || return 0
      [ "''${#reap_hooks[@]}" -gt 0 ] || return 0
      reap_rc=0
      while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        for hook in "''${reap_hooks[@]}"; do
          say "running profile route-change hook $hook [$phase] for $slug"
          if ! "$hook" "$slug" >&2; then
            say "error: $hook [$phase] $slug exited non-zero"
            reap_rc=1
          fi
        done
      done < <(printf '%s\n' "$reap_profiles")
      return "$reap_rc"
    }

    # Confirm that sing-box actually applied the SIGHUP reload (async Type=simple
    # ExecReload exits 0 on signal delivery even if sing-box's internal check()
    # rejects the config and keeps the old Box alive).
    confirm_reload() {
      pid="$1"
      cursor="$2"
      since="$3"
      case "$pid" in
        ""|*[!0-9]*|0)
          say "reload confirmation failed: invalid MainPID ($pid)"
          return 1
          ;;
      esac
      tick=0
      while [ "$tick" -lt "$reload_confirm_ticks" ]; do
        if [ -n "$cursor" ]; then
          jout="$("$journalctl_bin" -u "''${service_name}.service" --after-cursor="$cursor" "_PID=$pid" --no-pager -o cat 2>/dev/null || true)"
        else
          jout="$("$journalctl_bin" -u "''${service_name}.service" --since="$since" "_PID=$pid" --no-pager -o cat 2>/dev/null || true)"
        fi
        if printf '%s\n' "$jout" | "$grep_bin" -Fq "reload service:"; then
          err_line="$(printf '%s\n' "$jout" | "$grep_bin" -F "reload service:" | tail -n 1)"
          say "sing-box rejected SIGHUP reload: $err_line"
          return 1
        fi
        if printf '%s\n' "$jout" | "$grep_bin" -Fq "sing-box started"; then
          if kill -0 "$pid" 2>/dev/null; then
            return 0
          fi
          say "sing-box MainPID=$pid exited right after reload"
          return 1
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
          say "sing-box MainPID=$pid exited during reload"
          return 1
        fi
        "$sleep_bin" "$reload_poll_interval"
        tick=$((tick + 1))
      done
      say "timed out waiting for sing-box started after SIGHUP (MainPID=$pid)"
      return 1
    }

    fetch || fail "fetch: $(lastline)"
    if [ -s "$state/config.json" ] && same_renderer \
      && "$cmp_bin" -s "$work/raw.json" "$state/raw.json"; then
      say "config unchanged"
      report unchanged
      exit 0
    fi
    candidate="$({ sha256sum < "$work/raw.json"; printf '%s\n' "$stamp"; } | sha256sum | cut -c1-64)"
    if [ "$(cat "$state/rejected" 2>/dev/null || true)" = "$candidate" ]; then
      fail "this raw was rolled back here before ($(cat "$state/rejected.why" 2>/dev/null || true)) — not applied again"
    fi
    render || fail "render: $(lastline)"
    before="$(egress)"
    mkdir "$work/prev"
    for f in config.json raw.json render.id; do
      if [ -e "$state/$f" ]; then cp -p "$state/$f" "$work/prev/$f"; fi
    done

    # Classify whether the rendered config diff is eligible for an in-place
    # SIGHUP reload (only outbounds, endpoints, route.rules, and/or ephemeral
    # TUN exclude_interface churn changed) or requires a full systemctl restart.
    apply_mode="restart"
    apply_reason="no previous config or router not active"
    reap_profiles=""
    if [ -s "$work/prev/config.json" ] \
      && "$systemctl_bin" is-active --quiet "''${service_name}.service"; then
      if "$jq_bin" -n \
        --slurpfile prev "$work/prev/config.json" \
        --slurpfile next "$work/config.json" \
        -f "$classify_jq" > "$work/classify.json" 2>"$work/err"; then
        apply_mode="$("$jq_bin" -r '.action // "restart"' "$work/classify.json")"
        apply_reason="$("$jq_bin" -r '(.reasons // []) | join(",")' "$work/classify.json")"
        reap_profiles="$("$jq_bin" -r '(.reap_profiles // [])[]' "$work/classify.json")"
      else
        say "hot-reload classifier failed ($(lastline)) — falling back to full restart"
        apply_mode="restart"
        apply_reason="classifier-error"
      fi
    fi

    install_candidate

    # The tun takes a moment after reload/restart: up to 4 checks.
    # Anthropic reached ends the wait at once.
    check_egress() {
      first_sleep="$1"
      why="" after=""
      for i in 1 2 3 4; do
        if [ "$i" -eq 1 ]; then "$sleep_bin" "$first_sleep"; else "$sleep_bin" "$egress_retry_sleep"; fi
        after="$(egress)"
        why="$(worse "$before" "$after")"
        case "$why" in "" | *anthropic*) break ;; esac
      done
    }

    # Hold flock 9 across pre-reload reap, systemctl reload, journald confirm,
    # post-reload reap, and check_egress so concurrent update/fleet invocations
    # cannot send overlapping SIGHUPs or race rollback. Release flock 9 ONLY
    # immediately before any systemctl restart (whose ExecStartPre takes it).
    used_reload=0
    if [ "$apply_mode" = "reload" ] && [ -n "$reap_profiles" ]; then
      say "profile route removed/changed: $(printf '%s' "$reap_profiles" | tr '\n' ' ') — running pre-reload reap"
      if ! run_reap_hooks "pre-reload"; then
        say "pre-reload reap hook failed — falling back to full restart"
        apply_mode="restart"
        apply_reason="pre-reload-reap-failed"
      fi
    fi

    if [ "$apply_mode" = "reload" ]; then
      main_pid="$("$systemctl_bin" show -p MainPID --value "''${service_name}.service" 2>/dev/null || echo 0)"
      reload_cursor="$("$journalctl_bin" -u "''${service_name}.service" -n 0 --show-cursor --no-pager 2>/dev/null \
        | "$awk_bin" '/^-- cursor: / { sub(/^-- cursor: /, ""); print; exit }' || true)"
      reload_since="$("$date_bin" '+@%s' 2>/dev/null || true)"
      say "config changed (routes/outbounds only) — reloading ''${service_name} (MainPID=$main_pid, egress before: $before)"
      if "$systemctl_bin" reload "''${service_name}.service"; then
        if confirm_reload "$main_pid" "$reload_cursor" "$reload_since"; then
          used_reload=1
          if [ -n "$reap_profiles" ]; then
            if ! run_reap_hooks "post-reload"; then
              say "post-reload reap hook failed — falling back to full restart"
              used_reload=0
              apply_mode="restart"
              apply_reason="post-reload-reap-failed"
            fi
          fi
          if [ "$used_reload" = 1 ]; then
            check_egress "$egress_reload_sleep"
          fi
        else
          say "SIGHUP reload confirmation failed — falling back to full restart"
          apply_mode="restart"
          apply_reason="reload-unconfirmed"
        fi
      else
        say "systemctl reload ''${service_name} failed — falling back to full restart"
        apply_mode="restart"
        apply_reason="reload-failed"
      fi
    fi

    if [ "$apply_mode" != "reload" ]; then
      say "config changed (''${apply_reason:-structural}) — restarting ''${service_name} (egress before: $before)"
      # The router's ExecStartPre (startScript) takes the same lock.
      release_lock
      if "$systemctl_bin" restart "''${service_name}.service"; then
        check_egress "$egress_restart_sleep"
      else
        after="restart failed"
        why="''${service_name} failed to restart"
      fi
    fi

    if [ -z "$why" ]; then
      rm -f "$state/rejected" "$state/rejected.why"
      if [ "$used_reload" = 1 ]; then
        say "applied (hot-reloaded; egress after: $after)"
      else
        say "applied (egress after: $after)"
      fi
      report applied
      exit 0
    fi
    op_kind="restart"
    if [ "$used_reload" = 1 ]; then op_kind="reload"; fi
    say "egress worse after the $op_kind: $why (before: $before, after: $after)"
    [ -s "$work/prev/config.json" ] \
      || fail "$why — no previous config to roll back to"
    acquire_lock
    mv -f "$work/prev/config.json" "$state/config.json"
    if [ -e "$work/prev/raw.json" ]; then mv -f "$work/prev/raw.json" "$state/raw.json"; fi
    # The current stamp, so the router's start keeps the restored config
    # instead of re-rendering the restored raw.
    printf '%s\n' "$stamp" > "$state/render.id"
    printf '%s\n' "$candidate" > "$state/rejected"
    printf '%s\n' "$why" > "$state/rejected.why"
    release_lock
    "$systemctl_bin" restart "''${service_name}.service" \
      || fail "$why — rolled back, but ''${service_name} failed to restart"
    fail "$why — rolled back to $(sha256sum "$state/config.json" | cut -c1-12)"
    # END UCC_SINGBOX_UPDATE_SCRIPT
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
      ${updateScript} "$res" >&2 || true
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

  # Residual / conflicting TUN state:
  # - A crash or SIGKILL leaves priority-90xx rules + route table 2022 (auto_route)
  #   pointing at a dead tun — blackhole risk on next start.
  # - The pre-Nix installer (~/.local/ucc-sing-box, sudo ./bin/sing-box run -C .)
  #   claims the same TEST-NET addresses (192.0.2.0/30) and table 2022, so the
  #   managed unit dies with: "set routes: add route 0: file exists".
  # - table inet ${serviceName}-guard, an input filter on an auto_redirect
  #   port; nothing in this module creates it, so a start drops any found.
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
    ${delTunSubnetRules}

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

  # The tun's own subnets (the addresses the profile gives the tun: TEST-NET-1
  # and fdfe:dcba:9876::/126) go to main ahead of every other policy rule.
  # sing-tun's system stack answers each routed user's TCP SYN from its own
  # listener on the tun's address, as root, to the tun's peer address; the
  # include_uid rules (9000) send root past this tun's own table, so that
  # answer follows whatever rule comes next. Where a second auto_route tun's
  # table covers the subnet (agent-runtime's sandbox: table 2032 from rule
  # 9200, 192.0.0.0/9 via its tun0), the SYN-ACK went into that tun, which
  # reset it, and every routed user's TCP died at the handshake. main holds
  # the kernel's connected route while the tun is up; suppress_prefixlength 0
  # lets the lookup fall through when it is not. 5190 sorts ahead of
  # tailscale (5210+), sing-box (9000+) and agent-runtime (9200+).
  tunSubnetRules = [
    "-4 rule %s priority 5190 to 192.0.2.0/30 lookup main suppress_prefixlength 0"
    "-6 rule %s priority 5190 to fdfe:dcba:9876::/126 lookup main suppress_prefixlength 0"
  ];
  delTunSubnetRules = lib.concatMapStrings (r: ''
    while ${pkgs.iproute2}/bin/ip ${lib.replaceStrings [ "%s" ] [ "del" ] r} 2>/dev/null; do :; done
  '') tunSubnetRules;
  tunSubnetRule = pkgs.writeShellScript "${serviceName}-tun-subnet-rule" ''
    set +e
    ${delTunSubnetRules}
    ${lib.concatMapStrings (r: ''
      ${pkgs.iproute2}/bin/ip ${lib.replaceStrings [ "%s" ] [ "add" ] r} \
        || echo "${serviceName}: not installed: ip ${lib.replaceStrings [ "%s" ] [ "add" ] r}" >&2
    '') tunSubnetRules}
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

    onProfileRouteChange = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Executables invoked before AND immediately after an in-place hot-reload
        (`systemctl reload`) when an existing profile route is removed or its
        binding/guards change. Called once per affected profile slug with the
        slug as `$1`. Adding a brand-new profile route invokes no hooks. A
        non-zero exit falls back to a full `systemctl restart`.
      '';
    };

    fleet = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the -fleet socket, which applies each registry revision the mesh
        Worker pushes. Off, the unit is not in the system at all, so no
        switch or boot starts it: the router keeps its stored config, and a
        new one arrives only through -update by hand or the router's fetch on
        its first start after boot.
      '';
    };

    failClosed = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Render the rules of ./anthropic-failclosed.jq into the config. Off
        (the renderer hold on seat hosts) renders their IPv6 guards alone and
        ./failclosed-hold.jq in place of the rest: the shared node's OpenAI
        route, Anthropic refused for any flow no registry row claimed, any
        found process direct.
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
    # lookup for that source lands in main (eth0, not the tun) and drops it.
    # TCP and other UDP come back through the tun the same way (auto_redirect
    # is off), and the same exemption covers them. Cached names still answer,
    # so the symptom is "some names resolve, new ones time out". The kernel
    # names the tun (the first free tunN — EasyTier may hold tun0), so the
    # exemption keys on the address the profile gives it
    # (TEST-NET-1, the same one tunCleanup keys on), not on a name.
    networking.firewall.extraReversePathFilterRules = ''
      ip daddr 192.0.2.0/30 accept
      ip6 daddr fdfe:dcba:9876::/126 accept
    '';

    # The tun stack answers each routed user's TCP SYN itself: sing-tun's
    # system stack rewrites the SYN to its own listener on the tun's address
    # and writes it back into the tun, so the kernel sees a new inbound
    # connection on the tun. nixos-fw's input chain drops new connections on
    # an untrusted interface; without this accept every routed user's TCP
    # stalls at the handshake while DNS, answered in userspace, still works.
    # Keyed on a tun interface as well as the tun's addresses, so a packet
    # sent to TEST-NET from the LAN reaches no local listener.
    networking.firewall.extraInputRules = ''
      iifname "tun*" ip daddr 192.0.2.0/30 accept
      iifname "tun*" ip6 daddr fdfe:dcba:9876::/126 accept
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
      # Never stop or restart the live sing-box router during nixos-rebuild switch:
      # stopping it runs ExecStopPost (tearing down tun1 and firing full-desk PID
      # reapers). Emits X-RestartIfChanged=false and X-StopIfChanged=false so
      # switch-to-configuration updates the unit via daemon-reload while keeping
      # MainPID alive; sing-box-ucc-ucc-fleet/update apply config/renderer diffs
      # via hot-reload or deliberate restart.
      restartIfChanged = false;
      stopIfChanged = false;

      serviceConfig = {
        # Order: clear residue / kill legacy installer, the tun subnet rules,
        # then the start-only config script (decoupled from update/classifier/
        # onProfileRouteChange so update edits never mutate ExecStartPre).
        ExecStartPre = [
          "+${tunCleanup}"
          "+${tunSubnetRule}"
          "${startScript}"
        ];
        ExecStart = "${singboxPkg}/bin/sing-box -D ${stateDir} run -c ${liveConfig}";
        # In-place SIGHUP reload for route/outbound-only updates (keeps MainPID
        # alive so ExecStopPost teardown/reapers do not fire); re-ensures the
        # priority-5190 TUN subnet rules first.
        ExecReload = [
          "+${tunSubnetRule}"
          "${pkgs.util-linux}/bin/kill -HUP $MAINPID"
        ];
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
      description = "Refetch the UCC sing-box config for ${cfg.user}; reload or restart ${serviceName} when it changed";
      after = [
        "network-online.target"
        "sops-nix.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updateScript}";
      };
    };

    # The mesh Worker pushes each registry revision down this socket; the
    # client applies it and answers (plan § 3.4). No timer: a host that is
    # offline catches up on the revision it is sent at reconnect.
    systemd.services."${serviceName}-fleet" = lib.mkIf cfg.fleet {
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
        # Fixed 10 s on purpose: systemd's restart counter does not reset
        # on a healthy run, so a RestartSteps backoff would hold every
        # reconnect after the 5th drop at its ceiling.
        Restart = "always";
        RestartSec = 10;
      };
    };
  };
}
