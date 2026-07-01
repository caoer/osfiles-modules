# modules/net/easytier.nix — Standalone EasyTier mesh VPN service.
#
# Any NixOS host can opt in with `osf.easytier.enable = true`.
# Topology (ip, peers, subnets, listeners) is looked up from the injected
# mesh registry (osfLib.mesh) by hostname, so hosts only need to declare
# enable + provide the secret. Consumers inject their private mesh registry
# via `_module.args.osfLib` and point the sops-file options at their own
# encrypted secrets.
{
  config,
  lib,
  pkgs,
  osfLib,
  ...
}:
let
  cfg = config.osf.easytier;
  inherit (osfLib) mesh;
  wk = osfLib.wellKnown;
  nets = osfLib.networks;

  hostEntry = mesh.hosts.${cfg.hostname} or null;

  # Parse port from listener URI (e.g. "tcp://anyAddr:11010" → 11010).
  # Returns null for unparseable URIs; filtered out downstream.
  parseListenerPort =
    uri:
    let
      m = builtins.match ".*:([0-9]+)/?" uri;
    in
    if m != null then lib.toInt (builtins.head m) else null;

  # Unique listener ports from cfg.listeners, for firewall declarations.

  # Determine proto for a listener URI ("udp" for udp/quic, "tcp" for tcp/ws/wss).
  parseListenerProto =
    uri:
    let
      scheme = builtins.head (builtins.match "([a-z]+)://.*" uri);
    in
    if
      builtins.elem scheme [
        "udp"
        "quic"
      ]
    then
      "udp"
    else
      "tcp";

  # Build osf.network.services entries from listeners, grouping by port.
  # A port with both TCP and UDP listeners gets proto="both".
  listenerServices =
    let
      portProtos = builtins.foldl' (
        acc: uri:
        let
          port = parseListenerPort uri;
          proto = parseListenerProto uri;
        in
        if port == null then
          acc
        else
          acc
          // {
            ${toString port} =
              (acc.${toString port} or {
                inherit port;
                protos = [ ];
              }
              )
              // {
                protos = (acc.${toString port}.protos or [ ]) ++ [ proto ];
              };
          }
      ) { } cfg.listeners;

      mkService =
        _key: val:
        let
          protos = lib.unique val.protos;
          proto = if builtins.length protos > 1 then "both" else builtins.head protos;
        in
        {
          inherit (val) port;
          inherit proto;
          allow = [ "public" ];
          desc = "EasyTier listener";
        };
    in
    lib.mapAttrs' (key: val: lib.nameValuePair "easytier-${key}" (mkService key val)) portProtos;

  roleEntry =
    if hostEntry != null then
      mesh.roles.${hostEntry.role or "member"} or mesh.roles.member
    else
      mesh.roles.member;

  # Role flags + host flags, computed outside the module option to stay
  # additive with other modules that set cfg.extraFlags.
  roleExtraFlags =
    if hostEntry != null then (roleEntry.extraFlags or [ ]) ++ (hostEntry.extraFlags or [ ]) else [ ];

  # P2P flags from structured host.p2p attrset (mode, hole-punch toggles, etc.)
  p2pFlags = if hostEntry != null then mesh.mkP2pFlags (hostEntry.p2p or mesh.defaultP2p) else [ ];

  # Auth class (mesh.nix): "secret" = backbone (network_secret + secure-mode,
  # carries credential DB), "credential" = leaf (per-device credential, no secret).
  authClass = if hostEntry != null then (hostEntry.auth or "secret") else "secret";
  isBackbone = authClass == "secret";
  # Bootstrap-peer hubs are what new leaves dial into to join, so they must
  # reload the credential DB the moment it changes (see restartUnits below).
  isBootstrapPeer = builtins.elem cfg.hostname (map (p: p.name) mesh.bootstrapPeers);
  credentialDbPath = "/var/lib/easytier/credentials.json";

  easytierPkg = cfg.package;

  # Tailscale coexistence scripts — shared, byte-identical with modules/foreign/easytier.nix.
  # Rationale + the magicDnsRelay / CGNAT explanation live in lib/osf/easytierTailscaleFix.nix.
  tailscale = osfLib.easytierTailscaleFix { inherit pkgs; };

  startScript = osfLib.mkEasytierStartScript (
    {
      inherit pkgs easytierPkg;
      inherit (cfg)
        hostname
        ip
        peers
        subnets
        listeners
        ;
      inherit (mesh) networkName rpcPortal defaultProtocol;
      extraFlags = roleExtraFlags ++ p2pFlags ++ cfg.extraFlags;
      auth = authClass;
      secretPath =
        if isBackbone then
          config.sops.secrets.easytier-network-secret.path
        else
          config.sops.secrets.easytier-credential.path;
      credentialFilePath = if isBackbone then credentialDbPath else null;
    }
    // lib.optionalAttrs cfg.vpnPortal.enable {
      vpnPortal = {
        inherit (cfg.vpnPortal) listenPort clientCidr;
      };
    }
  );

in
{
  options.osf.easytier = {
    enable = lib.mkEnableOption "EasyTier mesh VPN";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/easytier.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../../packages/easytier.nix { }";
      description = "EasyTier package (easytier-core/easytier-cli).";
    };

    secrets = {
      networkSecretSopsFile = lib.mkOption {
        type = lib.types.path;
        description = "sops file carrying the `easytier-network-secret` key (backbone auth). Consumer-provided.";
      };

      credentialDbSopsFile = lib.mkOption {
        type = lib.types.path;
        description = "sops file carrying the `et_credential_db` key (backbone trust anchor). Consumer-provided.";
      };

      credentialsSopsFile = lib.mkOption {
        type = lib.types.path;
        description = "sops file carrying per-device `et_credential_<hostname>` keys (leaf auth). Consumer-provided.";
      };
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Mesh hostname. Defaults to networking.hostName. Must match a key in mesh.nix hosts.";
    };

    ip = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Mesh IP. Defaults to mesh.nix lookup by hostname.";
    };

    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Peer URIs. Defaults to mesh.nix lookup by hostname.";
    };

    subnets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Subnets to advertise. Defaults to mesh.nix lookup by hostname.";
    };

    listeners = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Listener URIs. Defaults to mesh.nix per-host override or defaultListeners.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra CLI flags passed to easytier-core (e.g. --secure-mode, --credential-file).";
    };

    tailscaleFix = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Coexist EasyTier magic DNS (${wk.easytier.magicDnsRelay}) with Tailscale: ip rule (routing) + INPUT ACCEPT (escape ts-input CGNAT drop). See tailscaleFixScript.";
    };

    vpnPortal = {
      enable = lib.mkEnableOption "EasyTier WireGuard VPN portal (fallback for non-native clients)";

      listenPort = lib.mkOption {
        type = lib.types.port;
        default = 11013;
        description = "UDP port for WireGuard portal listener.";
      };

      clientCidr = lib.mkOption {
        type = lib.types.str;
        default = nets.vpnPortalCidr;
        description = "Client address pool for WG portal peers.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Auto-populate from mesh.nix when host is registered
      (lib.mkIf (hostEntry != null) {
        osf.easytier = {
          ip = lib.mkDefault hostEntry.ip;
          peers = lib.mkDefault hostEntry.peers;
          subnets = lib.mkDefault hostEntry.subnets;
          listeners = lib.mkDefault (
            if hostEntry.listeners != null then hostEntry.listeners else roleEntry.listeners or [ ]
          );
        };
      })

      # Fallback listeners when host is not in mesh.nix
      (lib.mkIf (hostEntry == null) {
        osf.easytier.listeners = lib.mkDefault mesh.roles.member.listeners;
      })

      # Main service configuration
      {
        assertions = [
          {
            assertion = cfg.ip != "";
            message = "osf.easytier: no IP. Add '${cfg.hostname}' to mesh.nix or set osf.easytier.ip.";
          }
        ];

        systemd.services.easytier = {
          description = "EasyTier mesh VPN";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = "+${startScript}";
            Restart = "always";
            RestartSec = 5;
            AmbientCapabilities = [
              "CAP_NET_ADMIN"
              "CAP_NET_RAW"
            ];
            LimitNOFILE = 65536;
          }
          // lib.optionalAttrs cfg.tailscaleFix {
            ExecStartPost = "+${tailscale.fix}";
            ExecStopPost = "-${tailscale.cleanup}";
          };
        };

        # ── Firewall: module-owned port declarations ──────────────────
        # Listener ports declared via osf.network.services (zone-aware,
        # collision-detected). Ports derived from cfg.listeners URIs.
        osf.network.enable = lib.mkDefault true;
        osf.network.services = listenerServices;

        # Trust the mesh: accept all ports/protocols from internal mesh CIDRs
        # (overlay + VPN portal pool). The mesh is authenticated (network
        # secret + secure-mode), so peers are trusted at the firewall level.
        # Broader than per-port — blanket CIDR trust stays as extraInputRules.
        networking.firewall.extraInputRules = lib.concatMapStringsSep "\n" (
          cidr: ''ip saddr ${cidr} accept comment "trusted mesh peers"''
        ) mesh.meshCidrs;

        environment.systemPackages = [ easytierPkg ];
      }

      # Exit node: MASQUERADE mesh traffic out the default interface
      (lib.mkIf (builtins.elem "--enable-exit-node" (roleExtraFlags ++ cfg.extraFlags)) {
        boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault true;
        networking.nftables.tables.easytier-exit-nat = {
          family = "ip";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr ${mesh.meshSubnet} oifname "eth0" masquerade
            }
          '';
        };
      })

      # WG portal: open listen port, accept traffic from client subnet (trusted-only mesh)
      (lib.mkIf cfg.vpnPortal.enable {
        osf.network.services."easytier-vpn-portal" = {
          port = cfg.vpnPortal.listenPort;
          proto = "udp";
          allow = [ "public" ];
          desc = "EasyTier WG VPN portal";
        };
        networking.firewall.extraInputRules = ''
          ip saddr ${cfg.vpnPortal.clientCidr} accept
        '';
      })

      # Backbone: network_secret + credential DB (trust anchor). Every backbone
      # node loads the same DB and publishes the trusted credential pubkeys.
      (lib.mkIf isBackbone {
        sops.secrets.easytier-network-secret = {
          sopsFile = cfg.secrets.networkSecretSopsFile;
        };
        sops.secrets.easytier-credential-db = {
          sopsFile = cfg.secrets.credentialDbSopsFile;
          key = "et_credential_db";
          path = credentialDbPath;
          mode = "0400";
          # EasyTier loads the credential DB only at process start — no reload,
          # no SIGHUP, no watcher (verified in 2.6.4 + easytier-cli has no import
          # verb). So a plain sops deploy that changes the DB is a SILENT NO-OP
          # for credential trust until easytier restarts. Auto-restart fixes that,
          # but ONLY on bootstrap-peer hubs: a new leaf's pubkey propagates
          # mesh-wide via OSPF (HMAC-signed with network_secret) from any single
          # publisher, so restarting every backbone on each leaf add would flap
          # the mesh for zero reachability gain. Restarting the bootstrap hubs
          # (the dial-in anchors for new defaultPeers leaves) is sufficient.
          # Foreign bootstrap hubs (megabox, usca9-1000) get the equivalent from
          # the osf CLI — pushForeignSecrets() restarts easytier after pushing
          # secrets (cli/src/commands/rebuild.ts) — so only the NixOS path needs
          # this declarative hook.
          restartUnits = lib.optionals isBootstrapPeer [ "easytier.service" ];
        };
        systemd.tmpfiles.rules = [ "d /var/lib/easytier 0700 root root -" ];
      })

      # Credential leaf: per-device credential privkey, no network_secret.
      (lib.mkIf (!isBackbone) {
        sops.secrets.easytier-credential = {
          sopsFile = cfg.secrets.credentialsSopsFile;
          key = "et_credential_${cfg.hostname}";
        };
      })
    ]
  );
}
