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

  # ── Process bypass ────────────────────────────────────────────────
  route_direct_process_name ? [ ],

  # ── Direct routing CIDRs (mesh overlays, tailscale, etc.) ─────────
  route_direct_cidrs ? [
    "10.144.0.0/16"
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
  dnsDomestic ? { type = "udp"; tag = "dns-domestic"; server = "223.5.5.5"; },
  dnsForeign ? { type = "https"; tag = "dns-foreign"; server = "1.1.1.1"; path = "/dns-query"; },
  extraDnsServers ? [ ],
  extraDnsRules ? [ ],

  # ── Extra standalone outbounds (no urltest/selector wrapping) ──────
  extraOutbounds ? [ ],

  # ── Extra route rules (before mesh catch-alls) ────────────────────
  extraRouteRules ? [ ],

  # ── Clash API ─────────────────────────────────────────────────────
  clashApi ? null,
  apiService ? null,

  # ── Final outbound (catch-all route) ──────────────────────────────
  finalOutbound ? "proxy-select",

  # ── Geo-CN ruleset path (baked in) ────────────────────────────────
  geoCnPath,

  # ── http_clients ──────────────────────────────────────────────────
  httpClients ? [ ],

  # ── find_process ──────────────────────────────────────────────────
  find_process ? false,

  # ── DNS cache ──────────────────────────────────────────────────────
  dnsCacheCapacity ? null,
  dnsReverseMapping ? false,

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
  expandEntry = entry:
    if entry.shadowtls or false then
      let tag = entry.tag; in
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
  entryTag = entry:
    if entry.shadowtls or false then "ss-${entry.tag}" else entry.tag;

  # ── Process each outboundGroup ────────────────────────────────────

  groupNames = lib.attrNames outboundGroups;

  groupResolved = name:
    let
      entries = outboundGroups.${name}.outbounds or [ ];
    in
    {
      allOutbounds = lib.concatMap expandEntry entries;
      allTags = map entryTag entries;
    };

  groupHasUrltest = name: outboundGroups.${name}.urltest or true;
  groupInMainPool = name: outboundGroups.${name}.inMainPool or true;

  allGroupRawOutbounds =
    lib.concatMap (name: (groupResolved name).allOutbounds) groupNames;

  mkGroupMeta = name:
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
  directOutbound = [ { type = "direct"; tag = "direct"; } ];

  # ── Top-level urltest + selector ──────────────────────────────────
  mainPoolMembers =
    lib.concatMap (name:
      if groupInMainPool name then
        if groupHasUrltest name then [ name ]
        else (groupResolved name).allTags
      else [ ]
    ) groupNames;

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
    ++ [ urltestOutbound selectorOutbound ];

  # ── DNS ───────────────────────────────────────────────────────────
  foreignDnsServer = dnsForeign // { detour = dnsDetour; };

  dnsBlock = {
    servers = [ dnsDomestic foreignDnsServer ] ++ extraDnsServers;
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
    {
      type = "shadowsocks";
      tag = "ss-in";
      listen = "::";
      listen_port = shadowsocks_listen_port;
      method = shadowsocks_method;
      password = shadowsocks_password;
    }
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
    [
      { action = "sniff"; }
      { protocol = "dns"; action = "hijack-dns"; }
    ]
    ++ lib.optionals (route_direct_process_name != [ ]) [
      {
        action = "route";
        outbound = "direct";
        process_name = route_direct_process_name;
      }
    ]
    ++ extraRouteRules
    ++ lib.optionals (route_direct_cidrs != [ ]) [
      {
        ip_cidr = route_direct_cidrs;
        action = "route";
        outbound = "direct";
      }
    ]
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
    auto_detect_interface = true;
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
        if apiService != null then apiService.dashboardPath
        else "${cacheFilePath}/../dashboard";
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
