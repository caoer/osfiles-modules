# modules/net/gateway/mosdns.nix — MosDNS pluggable DNS forwarder + YAML config.
#
# Split DNS: foreignUpstreams selects per-host non-CN resolution path.
# Per-host mesh hosts via osf.gateway.mosdns.meshHosts.
{
  config,
  lib,
  pkgs,
  osfLib,
  ...
}:
let
  wk = osfLib.wellKnown;
  nets = osfLib.networks;

  cfg = config.osf.gateway;

  # Region profile: CN = split DNS inside the GFW; US = plain DoH outside it.
  isUS = cfg.mosdns.region == "US";

  # Geodata URLs — downloaded at runtime, not build time.
  # Consumer-provided via osf.gateway.mosdns.geodataUrls (only forced when
  # region = CN — US gateways never fetch geodata).
  geodataUrls = {
    geosite_cn = cfg.mosdns.geodataUrls.geositeCn;
    geosite_not_cn = cfg.mosdns.geodataUrls.geositeNotCn;
    geoip_cn = cfg.mosdns.geodataUrls.geoipCn;
  };

  # Script to fetch geodata files, skip if fresh (< 24h old)
  updateGeodata = pkgs.writeShellScript "mosdns-update-geodata" ''
    set -euo pipefail
    dir="${dataDir}"
    max_age=86400  # 24 hours

    fetch() {
      local name="$1"
      local url="$2"
      local dest="$dir/$name"
      if [ -f "$dest" ] && [ "$(( $(date +%s) - $(stat -c %Y "$dest") ))" -lt "$max_age" ]; then
        echo "mosdns-geodata: $name is fresh, skipping"
        return 0
      fi
      echo "mosdns-geodata: fetching $name"
      # System DNS (mosdns) not running yet — resolve via Alibaba public DNS
      local host
      host=$(echo "$url" | sed -E 's|https?://([^/]+)/.*|\1|')
      local resolved
      resolved=$(${pkgs.dnsutils}/bin/dig +short +timeout=5 "$host" @${wk.dns.alidns} A | grep -E '^[0-9]+\.' | head -1)
      if ${pkgs.curl}/bin/curl -4 -fsSL --connect-timeout 10 --max-time 60 \
          ''${resolved:+--resolve "$host:443:$resolved"} \
          -o "$dest.tmp" "$url"; then
        mv "$dest.tmp" "$dest"
        echo "mosdns-geodata: $name updated"
      else
        rm -f "$dest.tmp"
        if [ -f "$dest" ]; then
          echo "mosdns-geodata: fetch failed, using stale $name"
        else
          echo "mosdns-geodata: fetch failed and no cached $name, aborting" >&2
          return 1
        fi
      fi
    }

    fetch geosite_cn.txt "${geodataUrls.geosite_cn}"
    fetch geosite_not_cn.txt "${geodataUrls.geosite_not_cn}"
    fetch geoip_cn.txt "${geodataUrls.geoip_cn}"
  '';

  dataDir = "/var/lib/mosdns/data";

  hasExtraCn = cfg.mosdns.extraCnDomains != [ ];

  hasMeshHosts = cfg.mosdns.meshHosts != [ ];

  # Split DNS: domains resolved to mesh IPs for on-mesh clients.
  meshHostsFile = pkgs.writeText "mesh-hosts.txt" (
    lib.concatMapStringsSep "\n" (h: "${h.domain} ${h.ip}") cfg.mosdns.meshHosts
  );

  forwardUsConcurrent = lib.min 3 (builtins.length cfg.dns.foreignUpstreams);

  # MosDNS uses '$' prefix for plugin references in sequence args.
  # These must be literal strings in YAML, not Nix interpolations.
  # pkgs.formats.yaml handles quoting correctly.
  yamlFormat = pkgs.formats.yaml { };

  # ── Plugin building blocks ──
  # Shared across both regions (mesh-internal resolution + servers). CN-only
  # blocks (geosite/geoip data sets, forward_cn, fallback) are below and are
  # only referenced by cnPlugins, so they are never forced when region = US.

  # Mesh-internal data sets (both regions).
  dsK8s = {
    tag = "k8s_domains";
    type = "domain_set";
    args.exps = [ "domain:lockin.mesh" ];
  };
  dsTailscale = {
    tag = "tailscale_domains";
    type = "domain_set";
    args.exps = [ "domain:${cfg.tailnetName}" ];
  };
  dsEt = {
    tag = "et_domains";
    type = "domain_set";
    args.exps = [ "domain:et.net" ];
  };
  dsMeshHosts = {
    tag = "mesh_hosts";
    type = "hosts";
    args.files = [ "${meshHostsFile}" ];
  };

  # Mesh-internal forwarders + US/foreign forwarder (both regions).
  fwdEt = {
    tag = "forward_et";
    type = "forward";
    args.upstreams = [ { addr = wk.easytier.magicDnsRelay; } ];
  };
  fwdUs = {
    tag = "forward_us";
    type = "forward";
    args = {
      concurrent = forwardUsConcurrent;
      upstreams = map (addr: { inherit addr; }) cfg.dns.foreignUpstreams;
    };
  };
  fwdK8s = {
    tag = "forward_k8s";
    type = "forward";
    args.upstreams = [ { addr = nets.k8s.coreDns; } ];
  };
  fwdTailscale = {
    tag = "forward_tailscale";
    type = "forward";
    args.upstreams = [ { addr = wk.easytier.magicDns; } ];
  };

  pCache = {
    tag = "cache";
    type = "cache";
    args = {
      size = 4096;
      lazy_cache_ttl = 86400;
      dump_file = "/var/lib/mosdns/cache.dump";
      dump_interval = 3600;
    };
  };

  pUdpServer = {
    tag = "udp_server";
    type = "udp_server";
    args = {
      entry = "main";
      listen = "${wk.localhost}:5353";
    };
  };
  pTcpServer = {
    tag = "tcp_server";
    type = "tcp_server";
    args = {
      entry = "main";
      listen = "${wk.localhost}:5353";
    };
  };

  # Mesh-internal sequence prefix — identical in both regions. Resolves mesh
  # hosts, et.net, k8s, tailscale, and caches before region-specific routing.
  meshSeqPrefix =
    lib.optionals hasMeshHosts [
      { exec = "$mesh_hosts"; }
      {
        matches = "has_resp";
        exec = "return";
      }
    ]
    ++ [
      # et.net mesh is IPv4-only (infraSubnet): magic DNS only
      # answers A. AAAA (28) / SRV / HTTPS / SOA it silently drops ->
      # 5s forward timeout -> SERVFAIL retry storms (a single offline
      # mesh host pinned ~8% of all gateway DNS via AAAA). Return NODATA
      # fast for anything that isn't an A query.
      {
        matches = [
          "qname $et_domains"
          "!qtype 1"
        ];
        exec = "reject 0";
      }
      {
        matches = "qname $et_domains";
        exec = "$forward_et";
      }
      {
        matches = "qname $et_domains";
        exec = "return";
      }
      { exec = "$cache"; }
      {
        matches = "qname $k8s_domains";
        exec = "$forward_k8s";
      }
      {
        matches = "qname $k8s_domains";
        exec = "return";
      }
      {
        matches = "qname $tailscale_domains";
        exec = "$forward_tailscale";
      }
      {
        matches = "qname $tailscale_domains";
        exec = "return";
      }
    ];

  # ── CN-only blocks (split DNS inside the GFW) ──
  dsGeositeCn = {
    tag = "geosite_cn";
    type = "domain_set";
    args.files = [ "${dataDir}/geosite_cn.txt" ];
  };
  dsGeositeNotCn = {
    tag = "geosite_not_cn";
    type = "domain_set";
    args.files = [ "${dataDir}/geosite_not_cn.txt" ];
  };
  dsGeoipCn = {
    tag = "geoip_cn";
    type = "ip_set";
    args.files = [ "${dataDir}/geoip_cn.txt" ];
  };
  dsCustomCn = {
    tag = "custom_cn";
    type = "domain_set";
    args.exps = cfg.mosdns.extraCnDomains;
  };
  fwdCn = {
    tag = "forward_cn";
    type = "forward";
    args = {
      concurrent = 2;
      upstreams = [
        { addr = wk.dns.alidns; }
        { addr = wk.dns.dnspod; }
      ];
    };
  };
  pFallback = {
    tag = "fallback";
    type = "sequence";
    args = [
      { exec = "$forward_cn"; }
      {
        matches = "!resp_ip $geoip_cn";
        exec = "$forward_us";
      }
    ];
  };
  mainCn = {
    tag = "main";
    type = "sequence";
    args =
      meshSeqPrefix
      ++ lib.optionals hasExtraCn [
        {
          matches = "qname $custom_cn";
          exec = "$forward_cn";
        }
        {
          matches = "qname $custom_cn";
          exec = "return";
        }
      ]
      ++ [
        {
          matches = "qname $geosite_cn";
          exec = "$forward_cn";
        }
        {
          matches = "qname $geosite_cn";
          exec = "return";
        }
      ]
      # v4-only egress: foreign AAAA has no proxy path (sing-box TUN is IPv4
      # only) and the CN fallback leaks GFW-poisoned AAAA (2001::1). Return
      # NODATA for foreign + unknown AAAA so clients use A through the proxy.
      # CN domains keep AAAA above (native v6 egress via the LAN router).
      ++ lib.optionals cfg.mosdns.dropForeignAAAA [
        {
          matches = [
            "qname $geosite_not_cn"
            "qtype 28"
          ];
          exec = "reject 0";
        }
        {
          matches = [
            "qname $geosite_not_cn"
            "qtype 28"
          ];
          exec = "return";
        }
      ]
      ++ [
        {
          matches = "qname $geosite_not_cn";
          exec = "$forward_us";
        }
        {
          matches = "qname $geosite_not_cn";
          exec = "return";
        }
      ]
      # Unknown domains (in neither geosite list) hit $fallback, which queries
      # forward_cn first — the exact path that returns GFW-poisoned 2001::1
      # for AAAA. Drop AAAA here too; unknown egresses v4 (CN direct or proxy).
      ++ lib.optionals cfg.mosdns.dropForeignAAAA [
        {
          matches = "qtype 28";
          exec = "reject 0";
        }
        {
          matches = "qtype 28";
          exec = "return";
        }
      ]
      ++ [
        { exec = "$fallback"; }
      ];
  };

  # ── US main (plain DoH outside the GFW) ──
  # No geosite/geoip split, no GFW-poison detection. Mesh-internal handled by
  # meshSeqPrefix; everything else goes straight to the foreign DoH upstream.
  mainUs = {
    tag = "main";
    type = "sequence";
    args = meshSeqPrefix ++ [
      { exec = "$forward_us"; }
    ];
  };

  # ── Compose per region ──
  # CN path is byte-identical to the pre-region config (same attrsets, same
  # order) — existing CN gateways see no closure churn.
  cnPlugins = [
    dsGeositeCn
    dsGeositeNotCn
    dsGeoipCn
    dsK8s
    dsTailscale
    dsEt
  ]
  ++ lib.optionals hasExtraCn [ dsCustomCn ]
  ++ lib.optionals hasMeshHosts [ dsMeshHosts ]
  ++ [
    fwdEt
    fwdCn
    fwdUs
    fwdK8s
    fwdTailscale
    pCache
    pFallback
    mainCn
    pUdpServer
    pTcpServer
  ];

  usPlugins = [
    dsK8s
    dsTailscale
    dsEt
  ]
  ++ lib.optionals hasMeshHosts [ dsMeshHosts ]
  ++ [
    fwdEt
    fwdUs
    fwdK8s
    fwdTailscale
    pCache
    mainUs
    pUdpServer
    pTcpServer
  ];

  plugins = if isUS then usPlugins else cnPlugins;

  configFile = yamlFormat.generate "mosdns.yaml" { inherit plugins; };

  mosdnsPkg = pkgs.mosdns;

in
lib.mkIf (cfg.enable && cfg.mosdns.enable) {
  systemd.services.mosdns = {
    description = "MosDNS pluggable DNS forwarder";
    after = [
      "network-online.target"
      "easytier.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # US gateways skip the geodata fetch entirely: there is no CN split to feed,
    # and the fetch resolves sources via AliDNS — slow/unreliable
    # from the US, which crash-loops the service at start.
    preStart = ''
      mkdir -p ${dataDir}
    ''
    + lib.optionalString (!isUS) ''
      ${updateGeodata}
    '';

    serviceConfig = {
      ExecStart = "${mosdnsPkg}/bin/mosdns start -c ${configFile}";
      Restart = "on-failure";
      RestartSec = 5;
      StateDirectory = "mosdns";
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    };
  };

  environment.systemPackages = [ mosdnsPkg ];
}
