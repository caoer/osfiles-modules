# modules/obs-site.nix (nixosModules.osf-obs-site) — the collector-rs observability site stack on a fleet host.
#
# Runs the processes collector-rs obs/site/services.toml declares (VictoriaMetrics, VictoriaLogs, Grafana, vmalert,
# Alertmanager, obs-bridge, vmauth) from the same obs/site/ files, at the versions collector-rs infra/pins.toml pins.
# collector-rs infra/fleet/default.nix renders each entry — the pin's nixpkgs package (evaluation fails when its
# version differs from the pin), obs-bridge built from the tree — and this module runs it as the unit
# obs-site-<name>. The tree is `src`: each consumer pins collector-rs as its own non-flake input and passes it, so
# its lock rev is the deployed sha. Contract, ingress and token: collector-rs infra/fleet/README.md.
#
# A host may run part of the stack: `run` names its entries, `remote` gives the address of the host that runs an
# entry referenced from here. With `user` null the units are system services as the obs-site user; with `user` set
# they are that user's home-manager user units — the alert plane on a UCC host, where obs-bridge spawns seats through
# the user's ccc-agent. `copies` runs an entry a second time under another name, against another site's stores.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.obsSite;
  inherit (lib) mkOption types;
  esc = lib.escapeShellArg;
  unit = n: "obs-site-${n}";
  system = cfg.user == null;

  fleet = import "${cfg.src}/infra/fleet" {
    inherit (cfg) pkgs;
    inherit (cfg)
      src
      portBase
      dataDir
      hostAddress
      run
      remote
      ;
  };
  inherit (fleet) services;

  # A copy is its entry's process again under its own name: -httpListenAddr moved to the copy's port on loopback,
  # the copy's args after the entry's (a one-value Victoria flag keeps its last).
  copy =
    n: c:
    let
      s = services.${c.of} or (throw "osf.obsSite.copies.${n}: ${c.of} is not an entry this host runs");
      listen = lib.hasPrefix "-httpListenAddr=";
    in
    assert lib.assertMsg (lib.count listen s.args == 1)
      "osf.obsSite.copies.${n}: ${c.of} does not have exactly one -httpListenAddr= argument to move";
    s
    // {
      name = n;
      inherit (c) port;
      args = lib.filter (a: !listen a) s.args ++ [ "-httpListenAddr=127.0.0.1:${toString c.port}" ] ++ c.args;
    };
  units = services // lib.mapAttrs copy cfg.copies;

  # The unit's process: directories and links the entry declares, its env (exported here so systemd expands nothing),
  # each pass_env variable from its file, then the binary — as infra/site.sh's per-unit script does.
  script =
    s:
    pkgs.writeShellScript "obs-site-${s.name}" ''
      set -euo pipefail
      mkdir -p ${esc cfg.dataDir} ${esc s.workdir}${
        lib.optionalString (s.dataSubdir != "") " ${esc "${cfg.dataDir}/${s.dataSubdir}"}"
      }
      ${lib.concatStrings (
        lib.mapAttrsToList (link: target: ''
          mkdir -p "$(dirname ${esc link})"
          ln -sfn ${esc target} ${esc link}
        '') s.links
      )}
      ${lib.concatStrings (
        lib.mapAttrsToList (k: v: "export ${k}=${esc v}\n") (s.env // (cfg.env.${s.name} or { }))
      )}
      ${lib.concatMapStrings (v: ''
        ${v}=$(< ${if system then "\"$CREDENTIALS_DIRECTORY/${v}\"" else esc cfg.envFiles.${v}})
        [ -n "''$${v}" ] || { echo "obs-site-${s.name}: ${v} is empty" >&2; exit 1; }
        export ${v}
      '') s.passEnv}
      cd ${esc s.workdir}
      exec ${esc s.exec} ${lib.escapeShellArgs (s.args ++ (cfg.args.${s.name} or [ ]))}
    '';

  deps = s: map (d: "${unit d}.service") s.after;
  userPath = lib.concatStringsSep ":" [
    (lib.makeBinPath [
      pkgs.bash
      pkgs.coreutils
      pkgs.tmux
      pkgs.systemd
    ])
    "/run/wrappers/bin"
    "/etc/profiles/per-user/${cfg.user}/bin"
    "/run/current-system/sw/bin"
  ];
  portsOn = names: map (n: services.${n}.port) names;
in
{
  options.osf.obsSite = {
    enable = lib.mkEnableOption "the collector-rs observability site stack (collector-rs obs/site/services.toml)";

    src = mkOption {
      type = types.path;
      example = lib.literalExpression "inputs.collector-rs-src";
      description = "The collector-rs tree at the deployed sha: the consumer's non-flake collector-rs input.";
    };

    pkgs = mkOption {
      type = types.pkgs;
      default = pkgs;
      defaultText = lib.literalExpression "pkgs";
      example = lib.literalExpression "inputs.nixpkgs-obs.legacyPackages.x86_64-linux";
      description = ''
        The nixpkgs the stack's binaries come from. Evaluation fails when a package's version differs from collector-rs
        infra/pins.toml, so a host whose own nixpkgs differs passes one at the pin's rev ([nix].nixpkgs_rev there).
      '';
    };

    run = mkOption {
      type = types.listOf types.str;
      description = "The services.toml entries this host runs.";
    };

    remote = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Entry name → address of the host that runs it, for each entry an entry here reaches.";
    };

    hostAddress = mkOption {
      type = types.str;
      description = "{{host}} for the entries run here: the address a browser or another host reaches this host on.";
    };

    portBase = mkOption {
      type = types.port;
      default = 8428;
      description = "The stack's port base; an entry listens on portBase + its port_offset.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/obs-site";
      description = "{{data_dir}}: the stack's state directory on this host.";
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "null: system services as the obs-site user. A user name: that user's home-manager user units.";
    };

    envFiles = mkOption {
      type = types.attrsOf types.path;
      default = { };
      description = "pass_env variable → file holding its value (system units read it through LoadCredential).";
    };

    env = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = { };
      example = {
        obs-bridge.OBS_BRIDGE_NOTIFY = "on";
      };
      description = "Entry name → variables set over that entry's services.toml env.";
    };

    args = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      example = {
        vl = [ "-retentionPeriod=90d" ];
      };
      description = ''
        Entry name → arguments appended after that entry's services.toml args. A Victoria flag that takes one value
        keeps its last, so an argument here overrides one services.toml sets; a list flag (-httpListenAddr) takes
        both values.
      '';
    };

    copies = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            of = mkOption {
              type = types.str;
              description = "The entry run here whose process the copy runs again.";
            };
            port = mkOption {
              type = types.port;
              description = "The copy's -httpListenAddr port, on 127.0.0.1.";
            };
            args = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Appended after the entry's services.toml args; `args.<of>` does not reach the copy.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          vmalert-stex = {
            of = "vmalert";
            port = 8536;
            args = [ "-datasource.url=https://obs-read.example.com" ];
          };
        }
      '';
      description = ''
        Name → a second unit obs-site-<name> of a Victoria entry run here, pointed elsewhere by its args: a vmalert
        that evaluates the same rules against another site's store.
      '';
    };

    builds = mkOption {
      type = types.attrsOf types.package;
      readOnly = true;
      description = "Crate → its package built from src (obs-bridge's carries obs-bridge and obs-notify).";
    };

    ports = mkOption {
      type = types.attrsOf types.port;
      readOnly = true;
      description = "Entry name → its port (portBase + port_offset), for an ingress or a peer host to point at.";
    };

    openFirewall = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      example = {
        tun0 = [
          "vm"
          "vl"
        ];
      };
      description = "Interface → entries run here whose ports open on it.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = lib.concatMap (
          s:
          map (v: {
            assertion = cfg.envFiles ? ${v};
            message = "osf.obsSite: ${s.name} passes ${v} from the environment; set osf.obsSite.envFiles.${v}";
          }) s.passEnv
        ) (lib.attrValues services)
        ++ map (n: {
          assertion = lib.elem n cfg.run;
          message = "osf.obsSite.env.${n}: ${n} is not an entry this host runs";
        }) (lib.attrNames cfg.env)
        ++ map (n: {
          assertion = lib.elem n cfg.run;
          message = "osf.obsSite.args.${n}: ${n} is not an entry this host runs";
        }) (lib.attrNames cfg.args)
        ++ map (n: {
          assertion = !(fleet.ports ? ${n});
          message = "osf.obsSite.copies.${n}: ${n} is a services.toml entry; a copy takes a name of its own";
        }) (lib.attrNames cfg.copies);

        osf.obsSite.ports = fleet.ports;
        osf.obsSite.builds = fleet.builds;

        networking.firewall.interfaces = lib.mapAttrs (_: names: {
          allowedTCPPorts = portsOn names;
        }) cfg.openFirewall;
      }

      (lib.mkIf system {
        users.users.obs-site = {
          isSystemUser = true;
          group = "obs-site";
          home = cfg.dataDir;
        };
        users.groups.obs-site = { };
        systemd.tmpfiles.rules = [ "d ${cfg.dataDir} 0750 obs-site obs-site -" ];

        systemd.services = lib.mapAttrs' (
          n: s:
          lib.nameValuePair (unit n) {
            description = "obs site stack: ${n} (collector-rs obs/site/services.toml)";
            wantedBy = [ "multi-user.target" ];
            wants = [ "network-online.target" ] ++ deps s;
            after = [ "network-online.target" ] ++ deps s;
            # A remote entry may be away for a while; keep retrying rather than give up after five starts.
            unitConfig.StartLimitIntervalSec = 0;
            serviceConfig = {
              ExecStart = script s;
              User = "obs-site";
              Group = "obs-site";
              Restart = "on-failure";
              RestartSec = 5;
              LoadCredential = map (v: "${v}:${cfg.envFiles.${v}}") s.passEnv;
            };
          }
        ) units;
      })

      (lib.mkIf (!system) {
        home-manager.users.${cfg.user}.systemd.user.services = lib.mapAttrs' (
          n: s:
          lib.nameValuePair (unit n) {
            Unit = {
              Description = "obs site stack: ${n} (collector-rs obs/site/services.toml)";
              Wants = deps s;
              After = deps s;
              StartLimitIntervalSec = 0;
            };
            Service = {
              ExecStart = "${script s}";
              Restart = "on-failure";
              RestartSec = 5;
              Environment = [ "PATH=${userPath}" ];
            };
            Install.WantedBy = [ "default.target" ];
          }
        ) units;
      })
    ]
  );
}
