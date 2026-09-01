# lib/singbox-config-generator.nix — opinionated sing-box config generator.
#
# Pure function: returns { config = <attrset>; json = <string>; }.
#
# Mode: "gateway" (TUN transparent proxy for forwarded + host traffic).
#
# All proxy outbounds are declared through `outboundGroups`. Each group
# contains a list of outbound definitions (attrsets). The generator wraps
# each group in a urltest + selector. All groups feed into a top-level
# `proxy-select` selector.
#
# Shadowtls convenience: an outbound entry with `shadowtls = true` is
# auto-expanded into a stls wrapper + inner ss pair using `shadowtlsDefaults`.
{ lib }:

{
  mode ? "gateway",

  # ── Outbound groups ───────────────────────────────────────────────
  #
  # Each group contains `outbounds` — a list of outbound attrsets.
  # The generator auto-creates urltest-<name> + <name> selector per group.
  #
  # Options per group:
  #   outbounds  — list of outbound attrsets
  #   urltest    — bool (default true). false skips urltest/selector.
  #   inMainPool — bool (default true). false excludes from proxy-select.
  #
  # Shadowtls shorthand: entries with `shadowtls = true` are expanded
  # into a pair (stls wrapper + inner ss) using shadowtlsDefaults.
  # Required fields: server, port. The rest comes from shadowtlsDefaults.
  #
  # Example:
  #   outboundGroups = {
  #     stls = {
  #       outbounds = [
  #         { tag = "bwg-megabox"; server = "144.34.230.170"; port = 23061; shadowtls = true; }
  #         { tag = "dmit-lax";    server = "2605:52c0:2:..."; port = 23061; shadowtls = true; }
  #       ];
  #     };
  #     gateway-cd = {
  #       outbounds = [
  #         { type = "shadowsocks"; tag = "to-core-rs"; server = "127.0.0.1"; ... }
  #       ];
  #     };
  #     coscene-hq = {
  #       urltest = false;
  #       inMainPool = false;
  #       outbounds = [ { type = "shadowsocks"; tag = "coscene-hq"; ... } ];
  #     };
  #   };
  outboundGroups ? { },

  # ── ShadowTLS fleet defaults ──────────────────────────────────────
  # Used when expanding entries with `shadowtls = true`.
  shadowtlsDefaults ? {
    version = 3;
    sni = "swcdn.apple.com";
    ssMethod = "2022-blake3-aes-256-gcm";
    ssPassword = "";
    password = "";
  },

  # ── urltest probe URL ─────────────────────────────────────────────
  urltestUrl ? "https://www.gstatic.com/generate_204",
  urltestInterval ? "5m",

  # ── TUN configuration ─────────────────────────────────────────────
  interface_name ? "tun-gw",
  # Accepts a string (single address) or a list (e.g. [ipv4 ipv6]).
  tun_address ? "172.19.0.1/30",
  exclude_interface ? [ ],
  route_exclude_address ? [ ],

  # ── DNS listener (gateway serves DNS to LAN clients) ───────────────
  # When true, adds a direct inbound on :53. hijack-dns routes queries
  # to the sing-box DNS engine (split DNS: CN → domestic, foreign → proxy).
  dnsListen ? true,
  dnsListenPort ? 53,
  dnsListenAddress ? "0.0.0.0",

  # ── Optional inbound ports ────────────────────────────────────────
  mixed_listen_port ? null,
  shadowsocks_listen_port ? null,
  shadowsocks_password ? "SECRET_PLACEHOLDER",
  shadowsocks_method ? "2022-blake3-aes-256-gcm",
  # Accept sing-box multiplex (smux/yamux/h2mux) on the SS inbound.
  # Transparent to non-mux clients (Surge et al.) — mux is detected via the
  # special sp.mux.sing-box.arpa destination, plain SS passes through.
  shadowsocks_multiplex ? false,

  # ── Process bypass ────────────────────────────────────────────────
  # Processes that must always go direct (mesh VPN, benchmarks, etc.)
  route_direct_process_name ? [
    "easytier-core"
    "easytier-cli"
    "iperf"
    "iperf3"
  ],

  # ── Direct routing CIDRs (mesh overlays, tailscale, etc.) ─────────
  route_direct_cidrs ? [
    "10.56.0.0/16" # locus-mesh
    "10.60.0.0/14" # coscene-mesh (covers 10.61 robot/edge)
    "10.42.0.0/16"
    "10.43.0.0/16"
    "100.64.0.0/10"
  ],

  # ── Direct routing domains ────────────────────────────────────────
  route_direct_domains ? [
    ".lockin.mesh"
    ".et.net"
    ".cymric-marlin.ts.net"
  ],

  # ── DNS ───────────────────────────────────────────────────────────
  # Split DNS: CN domains → domestic (direct), everything else → foreign (via proxy).
  dnsDetour ? "proxy-select",
  # DoH, not plain UDP. A UDP DNS transport has no connection object, so a
  # blackholed flow (upstream rate-limit, NAT mapping evicted under load) is
  # invisible to sing-box: it keeps sending on the same dead socket forever
  # and every CN name stops resolving until the unit restarts. Observed live
  # on cos-stex-gw 2026-07-27 — 52 queries out, 0 replies, while a fresh
  # socket from the same host answered in 7ms. DoH rides an HTTP/2 connection
  # that fails and re-dials, so the same event self-heals in one query.
  dnsDomestic ? {
    type = "https";
    tag = "dns-domestic";
    server = "223.5.5.5";
    path = "/dns-query";
  },
  dnsForeign ? {
    type = "https";
    tag = "dns-foreign";
    server = "1.1.1.1";
    path = "/dns-query";
  },
  extraDnsServers ? [ ],
  extraDnsRules ? [ ],

  # ── Extra standalone outbounds (no urltest/selector wrapping) ──────
  extraOutbounds ? [ ],

  # ── Extra route rules (before mesh catch-alls) ────────────────────
  extraRouteRules ? [ ],

  # ── Pre-sniff route rules (the VERY FIRST rules, above `sniff`) ───
  # For ip_cidr rules on raw-IP destinations (mesh bands via a relay):
  # `action: route` is terminal, so matching flows skip sniff entirely.
  # Server-speaks-first protocols (SSH) otherwise pay the full sniff
  # timeout waiting for client bytes that never come — measured on
  # cos-stex-ucc: 1069ms vs 463ms connect to the same mesh address.
  # A raw-IP destination has no name to sniff and no DNS to hijack.
  preSniffRouteRules ? [ ],

  # ── Clash API ─────────────────────────────────────────────────────
  clashApi ? null,
  apiService ? null,

  # ── Final outbound (catch-all route) ──────────────────────────────
  finalOutbound ? "proxy-select",

  # ── Geo-CN ruleset (LOCAL path, nix-pinned from our R2 cache) ─────
  # MUST be a local file (rides the closure). A remote rule_set hard-fails
  # sing-box startup whenever cache.db lacks the tag (first boot, cache
  # wipe, corruption after unclean kill) — the initial fetch rides the
  # detour pool at t=0 and a dead member crash-loops the host's LAN DNS
  # (proven live on gateway-cq, 2026-07-03). Gateway DNS must come up with
  # ZERO network dependency at startup. Source from R2 at BUILD time
  # instead: packages/geo-cn-ruleset.nix (bump via update-geo-cn.sh).
  geoCnPath,

  # ── http_clients ──────────────────────────────────────────────────
  httpClients ? [ ],

  # ── find_process ──────────────────────────────────────────────────
  find_process ? false,

  # ── auto_detect_interface ─────────────────────────────────────────
  # sing-box derives ONE default interface (from the v4 default route)
  # and binds every direct dial to it. On hosts with asymmetric family
  # defaults (v4 and v6 on different NICs) that ENETUNREACHes the other
  # family — set false so the kernel routes per family. Loop prevention
  # under auto_redirect comes from the 0x2024 output mark, not binding.
  auto_detect_interface ? true,

  # ── DNS cache ──────────────────────────────────────────────────────
  dnsCacheCapacity ? null,
  dnsReverseMapping ? false,

  # ── DNS query timeout ─────────────────────────────────────────────
  # sing-box defaults to 10s. When an upstream stops answering, every
  # retry holds an in-flight slot for that full 10s; a client that retries
  # hard (tcp-over-redis reconnect, EasyTier STUN discovery) piles up
  # hundreds of them and starves the :53 inbound for every other LAN
  # client. 3s bounds the pile-up depth without failing slow-but-live
  # lookups.
  dnsTimeout ? "3s",

  # ── Cache file path ───────────────────────────────────────────────
  cacheFilePath ? "/var/lib/sing-box-tproxy/cache.db",

  # ── Log level ─────────────────────────────────────────────────────
  logLevel ? "info",
}:

let
  stls = shadowtlsDefaults;

  # Normalize tun_address: accept string or list.
  tunAddresses = if builtins.isList tun_address then tun_address else [ tun_address ];

  # ── Shadowtls pair expansion ──────────────────────────────────────
  # Entry with `shadowtls = true` → 2 outbounds (stls wrapper + inner ss).
  # Entry without → passed through as-is.
  expandEntry =
    entry:
    if entry.shadowtls or false then
      let
        tag = entry.tag;
      in
      [
        {
          type = "shadowtls";
          tag = "stls-${tag}";
          inherit (entry) server;
          server_port = entry.port;
          inherit (stls) version;
          password = stls.password;
          tls = {
            enabled = true;
            server_name = stls.sni;
            utls = {
              enabled = true;
              fingerprint = "chrome";
            };
          };
        }
        {
          type = "shadowsocks";
          tag = "ss-${tag}";
          method = stls.ssMethod;
          password = stls.ssPassword;
          udp_over_tcp = true;
          multiplex = {
            enabled = true;
            protocol = "smux";
            max_connections = 8;
            min_streams = 2;
            padding = true;
          };
          detour = "stls-${tag}";
        }
      ]
    else
      [ entry ];

  # The user-facing tag for urltest/selector membership.
  entryTag = entry: if entry.shadowtls or false then "ss-${entry.tag}" else entry.tag;

  # ── Process each outboundGroup ────────────────────────────────────

  groupNames = lib.attrNames outboundGroups;

  groupResolved =
    name:
    let
      entries = outboundGroups.${name}.outbounds or [ ];
    in
    {
      allOutbounds = lib.concatMap expandEntry entries;
      allTags = map entryTag entries;
    };

  groupHasUrltest = name: outboundGroups.${name}.urltest or true;
  groupInMainPool = name: outboundGroups.${name}.inMainPool or true;

  allGroupRawOutbounds = lib.concatMap (name: (groupResolved name).allOutbounds) groupNames;

  mkGroupMeta =
    name:
    let
      tags = (groupResolved name).allTags;
    in
    lib.optionals (groupHasUrltest name && tags != [ ]) [
      {
        type = "urltest";
        tag = "urltest-${name}";
        outbounds = tags;
        url = urltestUrl;
        interval = urltestInterval;
      }
      {
        type = "selector";
        tag = name;
        outbounds = [ "urltest-${name}" ] ++ tags;
        default = "urltest-${name}";
      }
    ];

  allGroupMeta = lib.concatMap mkGroupMeta groupNames;

  # ── Direct outbound ──────────────────────────────────────────────
  directOutbound = [
    {
      type = "direct";
      tag = "direct";
    }
  ];

  # ── Top-level urltest + selector ──────────────────────────────────
  # Loud failure over silent success: dnsDetour and finalOutbound
  # default to proxy-select, so an empty main pool would emit
  # urltest-all with zero members — sing-box rejects
  # that only at runtime (`sing-box check`), long after the build
  # reported success. Groups with zero outbounds are excluded (their
  # selector is never emitted — including them would leave a dangling
  # tag reference); a fully empty pool throws at eval time.
  mainPoolMembers =
    let
      members = lib.concatMap (
        name:
        let
          tags = (groupResolved name).allTags;
        in
        if !(groupInMainPool name) || tags == [ ] then
          [ ]
        else if groupHasUrltest name then
          [ name ]
        else
          tags
      ) groupNames;
    in
    if members == [ ] then
      throw ''
        singbox-config-generator: main proxy pool is empty — urltest-all and
        proxy-select would have zero members, which sing-box rejects only at
        runtime. Declare at least one outboundGroup with inMainPool = true and
        a non-empty `outbounds` list (osf.sing-box-gateway.outboundGroups /
        osf.gateway.edge.tproxy.outboundGroups).
      ''
    else
      members;

  urltestOutbound = {
    type = "urltest";
    tag = "urltest-all";
    outbounds = mainPoolMembers;
    url = urltestUrl;
    interval = urltestInterval;
  };

  selectorOutbound = {
    type = "selector";
    tag = "proxy-select";
    outbounds = [ "urltest-all" ] ++ mainPoolMembers ++ [ "direct" ];
    default = "urltest-all";
  };

  allOutbounds =
    directOutbound
    ++ allGroupRawOutbounds
    ++ allGroupMeta
    ++ extraOutbounds
    ++ [
      urltestOutbound
      selectorOutbound
    ];

  # ── DNS ───────────────────────────────────────────────────────────
  foreignDnsServer = dnsForeign // {
    detour = dnsDetour;
  };

  dnsBlock = {
    servers = [
      dnsDomestic
      foreignDnsServer
    ]
    ++ extraDnsServers;
    rules =
      extraDnsRules
      ++ [
        {
          rule_set = [ "geo-cn" ];
          action = "route";
          server = dnsDomestic.tag;
        }
      ]
      ++ lib.optionals (route_direct_domains != [ ]) [
        {
          domain_suffix = route_direct_domains;
          action = "route";
          server = dnsDomestic.tag;
        }
      ];
    final = foreignDnsServer.tag;
  }
  // lib.optionalAttrs (dnsTimeout != null) { timeout = dnsTimeout; }
  // lib.optionalAttrs (dnsCacheCapacity != null) { cache_capacity = dnsCacheCapacity; }
  // lib.optionalAttrs dnsReverseMapping { reverse_mapping = true; };

  # ── Inbounds ──────────────────────────────────────────────────────
  tunInbound = {
    type = "tun";
    tag = "tun-in";
    inherit interface_name;
    address = tunAddresses;
    auto_route = true;
    auto_redirect = true;
    strict_route = false;
    stack = "mixed";
  }
  // lib.optionalAttrs (exclude_interface != [ ]) {
    inherit exclude_interface;
  }
  // lib.optionalAttrs (route_exclude_address != [ ]) {
    inherit route_exclude_address;
  };

  mixedInbound = lib.optionals (mixed_listen_port != null) [
    {
      type = "mixed";
      tag = "mixed-in";
      listen = "::";
      listen_port = mixed_listen_port;
    }
  ];

  ssInbound = lib.optionals (shadowsocks_listen_port != null) [
    (
      {
        type = "shadowsocks";
        tag = "ss-in";
        listen = "::";
        listen_port = shadowsocks_listen_port;
        method = shadowsocks_method;
        password = shadowsocks_password;
      }
      // lib.optionalAttrs shadowsocks_multiplex {
        multiplex.enabled = true;
      }
    )
  ];

  dnsInbound = lib.optionals dnsListen [
    {
      type = "direct";
      tag = "dns-in";
      listen = dnsListenAddress;
      listen_port = dnsListenPort;
    }
  ];

  allInbounds = [ tunInbound ] ++ dnsInbound ++ mixedInbound ++ ssInbound;

  # ── Route rules ───────────────────────────────────────────────────
  routeRules =
    # Caller's pre-sniff rules first: terminal `route` actions for raw-IP
    # destinations that must never wait on the sniff timeout.
    preSniffRouteRules
    # Pre-sniff bypass: kernel-level direct for mesh/overlay CIDRs.
    # auto_redirect skips these at the kernel — never enters sing-box userspace.
    ++ lib.optionals (route_direct_cidrs != [ ]) [
      {
        ip_cidr = route_direct_cidrs;
        action = "bypass";
      }
    ]
    ++ [
      { action = "sniff"; }
      {
        protocol = "dns";
        action = "hijack-dns";
      }
    ]
    ++ lib.optionals (route_direct_process_name != [ ]) [
      {
        action = "route";
        outbound = "direct";
        process_name = route_direct_process_name;
      }
    ]
    ++ extraRouteRules
    ++ lib.optionals (route_direct_domains != [ ]) [
      {
        domain_suffix = route_direct_domains;
        action = "route";
        outbound = "direct";
      }
    ]
    ++ [
      {
        ip_is_private = true;
        action = "route";
        outbound = "direct";
      }
      {
        rule_set = [ "geo-cn" ];
        action = "route";
        outbound = "direct";
      }
    ];

  routeBlock = {
    rules = routeRules;
    final = finalOutbound;
    inherit auto_detect_interface;
    default_domain_resolver = dnsDomestic.tag;
    rule_set = [
      {
        tag = "geo-cn";
        type = "local";
        format = "source";
        path = geoCnPath;
      }
    ];
  }
  // lib.optionalAttrs find_process { inherit find_process; };

  # ── Experimental ──────────────────────────────────────────────────
  experimentalBlock = {
    cache_file = {
      enabled = true;
      path = cacheFilePath;
    };
  }
  // lib.optionalAttrs (clashApi != null) {
    clash_api = {
      external_controller = "${clashApi.host}:${toString clashApi.port}";
      external_ui =
        if apiService != null then apiService.dashboardPath else "${cacheFilePath}/../dashboard";
      secret = clashApi.secret or "CLASH_SECRET_PLACEHOLDER";
    };
  };

  servicesBlock = lib.optionals (apiService != null) [
    {
      type = "api";
      tag = "api";
      listen = apiService.host;
      listen_port = apiService.port;
      secret = apiService.secret or "CLASH_SECRET_PLACEHOLDER";
      dashboard = {
        enabled = true;
        path = apiService.dashboardPath;
      };
    }
  ];

  config = {
    log = {
      level = logLevel;
      timestamp = true;
    };
    dns = dnsBlock;
    inbounds = allInbounds;
    outbounds = allOutbounds;
    route = routeBlock;
    experimental = experimentalBlock;
  }
  // lib.optionalAttrs (httpClients != [ ]) {
    http_clients = httpClients;
  }
  // lib.optionalAttrs (servicesBlock != [ ]) {
    services = servicesBlock;
  };

in
{
  inherit config;
  json = builtins.toJSON config;
}
