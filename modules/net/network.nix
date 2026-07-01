# modules/net/network.nix — Structured network policy for hosts with zone-based access needs.
#
# Concepts:
#   Zone    — named CIDR group (mesh, lan). "public" is implicit (all sources).
#   Service — { port, proto, allow, desc } — what to expose, to whom.
#   NAT4    — structured IPv4 masquerade.
#   Extra tables — escape hatch for NAT6, port hopping, edge blackhole.
#
# Tuning (BBR, TFO) is unconditional. ip_forward auto-enables with NAT.
# Everything not listed above uses NixOS primitives directly.
{ config, lib, ... }:
let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkMerge
    types
    ;

  cfg = config.osf.network;

  # ── Zone resolution ─────────────────────────────────────────────
  # "public" → null sentinel (no source restriction).
  # Unknown zone → empty list (no rule emitted, no crash). [P1 #8]
  resolveCidrs = zoneName: if zoneName == "public" then null else cfg.zones.${zoneName} or [ ];

  resolveAllow =
    allowList:
    if builtins.elem "public" allowList then
      null
    else
      lib.unique (lib.concatMap resolveCidrs allowList);

  # ── Port collection ─────────────────────────────────────────────
  allServices = lib.attrValues cfg.services;
  isPublic = svc: builtins.elem "public" svc.allow;
  isRestricted = svc: !(isPublic svc) && svc.allow != [ ];
  protoMatch = want: svc: svc.proto == want || svc.proto == "both";

  publicTcpPorts = map (s: s.port) (lib.filter (s: isPublic s && protoMatch "tcp" s) allServices);
  publicUdpPorts = map (s: s.port) (lib.filter (s: isPublic s && protoMatch "udp" s) allServices);
  restrictedServices = lib.filter isRestricted allServices;

  # ── Comment sanitization [FUSED from Team A] ────────────────────
  # Strip quotes from service descriptions to prevent nftables syntax errors.
  # Simpler than escaping — nftables comments don't need quoted content.
  sanitizeComment = s: builtins.replaceStrings [ "\"" ] [ "" ] s;

  # ── ACL generation ──────────────────────────────────────────────
  fmtCidrs = cidrs: builtins.concatStringsSep ", " cidrs;

  mkServiceAcl =
    svc:
    let
      cidrs = resolveAllow svc.allow;
      protos =
        if svc.proto == "both" then
          [
            "tcp"
            "udp"
          ]
        else
          [ svc.proto ];
      comment = if svc.desc != "" then " comment \"${sanitizeComment svc.desc}\"" else "";
    in
    lib.concatMapStringsSep "" (
      proto:
      lib.optionalString (
        cidrs != null && cidrs != [ ]
      ) "ip saddr { ${fmtCidrs cidrs} } ${proto} dport ${toString svc.port} accept${comment}\n"
    ) protos;

  restrictedAcls = lib.concatMapStringsSep "" mkServiceAcl restrictedServices;

  # ── Port collision detection [P1 #7] ────────────────────────────
  portProtoKeys = lib.concatMap (
    svc:
    let
      protos =
        if svc.proto == "both" then
          [
            "tcp"
            "udp"
          ]
        else
          [ svc.proto ];
    in
    map (p: "${toString svc.port}/${p}") protos
  ) allServices;

  # ── Option types ────────────────────────────────────────────────
  serviceModule = types.submodule {
    options = {
      port = mkOption {
        type = types.port;
        description = "Service port.";
      };
      proto = mkOption {
        type = types.enum [
          "tcp"
          "udp"
          "both"
        ];
        description = "Protocol. 'both' = TCP + UDP rules.";
      };
      allow = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Zone names from osf.network.zones.
          "public" = open to all. [] = no rule (loopback only).
        '';
      };
      desc = mkOption {
        type = types.str;
        default = "";
        description = "Human label (nftables comment).";
      };
    };
  };

  nftTableModule = types.submodule {
    options = {
      family = mkOption {
        type = types.enum [
          "ip"
          "ip6"
          "inet"
        ];
        default = "inet";
      };
      content = mkOption {
        type = types.lines;
        description = "Raw nftables table content.";
      };
    };
  };
in
{
  options.osf.network = {

    enable = mkEnableOption "Structured network policy (zone-based ACLs)";

    zones = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      example = {
        mesh = [
          "<mesh infraSubnet>"
          "<vpnPortalCidr>"
        ];
        lan = [ "<cq lanSubnet>" ];
      };
      description = ''
        Named zones -> CIDR lists. "public" is reserved (implicit, all sources).
        Unknown zone names in service allow lists resolve to empty (no rule, no error).
      '';
    };

    services = mkOption {
      type = types.attrsOf serviceModule;
      default = { };
      description = "Service exposure registry. Firewall rules generated from this.";
    };

    nat = {
      enable = mkEnableOption "IPv4 NAT (masquerade)";
      internalInterface = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Internal interface (e.g. virbr0 side).";
      };
      externalInterface = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "External interface (e.g. LAN or WAN side).";
      };
    };

    extraTables = mkOption {
      type = types.attrsOf nftTableModule;
      default = { };
      description = "Raw nftables tables. Escape hatch for NAT6, port hopping, etc.";
    };
  };

  config = mkIf cfg.enable (mkMerge [

    # ── Assertions ──────────────────────────────────────────────
    {
      assertions = [
        {
          assertion = !(builtins.hasAttr "public" cfg.zones);
          message = "osf.network: 'public' is a reserved zone name.";
        }
        {
          assertion = builtins.length portProtoKeys == builtins.length (lib.unique portProtoKeys);
          message = "osf.network: port/proto collision — two services share the same port and protocol.";
        }
        {
          assertion =
            !cfg.nat.enable || (cfg.nat.internalInterface != null && cfg.nat.externalInterface != null);
          message = "osf.network.nat: both internalInterface and externalInterface required.";
        }
      ]
      # ── IPv6 CIDR validation [FUSED from Team C] ─────────────────
      # Per-zone assertion with specific error message naming the offending zone + CIDR.
      # ACL rules use `ip saddr` (IPv4 only). IPv6 CIDRs → nftables errors or silent bypass.
      ++ (lib.concatMap (
        zoneName:
        map (cidr: {
          assertion = !(lib.hasInfix ":" cidr);
          message = "osf.network.zones.${zoneName}: IPv6 CIDR '${cidr}' not supported. Use extraTables for IPv6 rules.";
        }) cfg.zones.${zoneName}
      ) (builtins.attrNames cfg.zones));
    }

    # ── nftables, firewall, tuning, NAT ─────────────────────────────
    {
      networking = {
        nftables.enable = true;
        nftables.tables = cfg.extraTables;

        firewall = {
          allowedTCPPorts = publicTcpPorts;
          allowedUDPPorts = publicUdpPorts;
          extraInputRules = lib.optionalString (restrictedAcls != "") restrictedAcls;
        };

        # NAT4 — gated on osf.network.nat.enable
        nat = mkIf cfg.nat.enable {
          enable = true;
          internalInterfaces = [ cfg.nat.internalInterface ];
          inherit (cfg.nat) externalInterface;
        };
      };

      # Tuning baseline (BBR + TFO). Lower priority (1500) so net-tuning.nix
      # presets (mkDefault = 1000) always win when both modules are active.
      # P0 #1: lib.optionalAttrs guards externalInterface interpolation —
      # when null, the attr name is never evaluated (no crash).
      boot.kernel.sysctl = {
        "net.core.default_qdisc" = lib.mkOverride 1500 "fq";
        "net.ipv4.tcp_congestion_control" = lib.mkOverride 1500 "bbr";
        "net.ipv4.tcp_fastopen" = lib.mkOverride 1500 3;
        # Disable IPv6 privacy/temporary addresses on servers. Temp addrs cause
        # UDP reply source mismatch: client sends to the stable EUI-64 addr,
        # kernel picks a temp addr for the reply, client drops it. TCP is immune
        # (connection-bound). Servers have no privacy need for temp addrs.
        "net.ipv6.conf.all.use_tempaddr" = lib.mkOverride 1500 0;
        "net.ipv6.conf.default.use_tempaddr" = lib.mkOverride 1500 0;
      }
      // lib.optionalAttrs cfg.nat.enable {
        "net.ipv4.ip_forward" = 1;
      }
      // lib.optionalAttrs (cfg.nat.enable && cfg.nat.externalInterface != null) {
        "net.ipv6.conf.all.forwarding" = 1;
        "net.ipv6.conf.${cfg.nat.externalInterface}.accept_ra" = 2;
      };
    }
  ]);
}
