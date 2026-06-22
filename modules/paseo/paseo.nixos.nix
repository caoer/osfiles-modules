# modules/paseo/paseo.nixos.nix — NixOS per-user paseo daemon module.
#
# Self-contained NixOS module for the paseo daemon. Extracted from
# modules/nixos/agent/{default,paseo}.nix.
#
# Hand-rolled per-user units (paseo-<user>.service) instead of the upstream
# single-instance NixOS module — uniform across the fleet and multi-user
# capable. The paseo PACKAGE comes from `osf.paseo.paseoPackage` (the flake's
# central pin by default; per-host overridable, R2).
#
# config.json is rendered into the store from the CONSUMER-SUPPLIED JSON
# (`osf.paseo.users.<name>.paseoConfigFile`, REQUIRED — R3) with the @UCC_BIN@
# placeholder replaced by the user's ucc bin dir, then materialized as a
# WRITABLE copy at ~/.paseo/config.json by a systemd ExecStartPre `install` —
# re-laid on every daemon start, so declarative content still wins. It is NOT a
# store symlink: paseo's onboard / config-save does an unconditional
# writeFileSync to that path, which EROFS-crashes against a read-only nix-store
# symlink — the writable copy fixes that while staying declarative. The file
# carries daemon.listen; multi-user hosts need a distinct port per user.
# ExecStartPre first rm -f's any stale read-only HM symlink (so `install` can't
# write THROUGH it back into the store), then installs the copy — silent
# mechanics, loud failure.
#
# Daemon identity (~/.paseo/server-id, daemon-keypair.json) is generated on
# first start and left alone — identity = host, back it up across reinstalls.
#
# Agent providers authenticate as the user — log in once interactively
# before relying on the daemon (BYOK).
#
# Factory form: `{ paseoFlake }: <nixos-module>`. The flake's outputs apply it
# with its own pinned `paseo`, so consumers need no paseo input. The paseo
# PACKAGE is overridable per-host via `osf.paseo.paseoPackage` (R2).
{ paseoFlake }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.paseo;
  paseoUsers = lib.filterAttrs (_: ucfg: ucfg.enable) cfg.users;
  paseoPkg = cfg.paseoPackage;

  # Shared render — same builder the Foreign system-manager module uses.
  agentLib = import ../ucc/lib.nix { inherit pkgs; };

  userOpts = lib.types.submodule (_: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run a paseo daemon for this user (paseo-<user>.service).";
      };
      paseoConfigFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          LEGACY: path to a static paseo config JSON (with @UCC_BIN@
          placeholder). Rendered into the store with ucc bin dir injected,
          then installed as a writable copy. Mutually exclusive with
          paseoConfig — if paseoConfig is set, this is ignored.
        '';
      };
      paseoConfig = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            listen = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1:6767";
              description = "daemon.listen address:port.";
            };
            relay = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { endpoint = "paseo-relay.innopals.com:443"; useTls = true; };
              description = "Relay config (endpoint, useTls, enabled).";
            };
            defaultLauncher = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Profile name for the default claude provider. null = ucc-auto.
                E.g. "opus48" → command is ucc-opus48, and that wrapper is
                excluded from the auto-discovered extra providers.
              '';
            };
            features = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { dictation = { enabled = false; }; voiceMode = { enabled = false; }; };
              description = "Feature flags (dictation, voiceMode).";
            };
            providerOverrides = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
              example = { glm = { additionalModels = [{ id = "glm-5.1"; label = "glm-5.1"; }]; }; };
              description = ''
                Per-provider overrides deep-merged onto discovered providers.
                Use for additionalModels, custom labels, or force-enabling a
                provider the scan would otherwise skip.
              '';
            };
          };
        });
        default = null;
        description = ''
          Structured paseo config — dynamic provider discovery from ucc-*
          wrappers at daemon start. When set, replaces paseoConfigFile.
          Providers are discovered from ~/.local/share/ucc/bin/ucc-* (laid
          down by ucc-update, which syncs from the worker DO).
        '';
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the plaintext paseo daemon password (e.g.
          a sops-nix secret path). Sets PASEO_PASSWORD env at daemon start —
          the daemon bcrypt-hashes it on boot. Required when listen is non-loopback.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra environment for the paseo daemon (e.g. PASEO_HOSTNAMES).";
      };
    };
  });

  # Agents spawned by the daemon need the user's tools: ucc-installed
  # claude/ccc-statusd (~/.local/bin, ucc bin), then HM/system profiles.
  #
  # /run/wrappers/bin MUST precede /run/current-system/sw/bin: the setuid
  # wrappers (sudo, mount, ping…) live there, while sw/bin holds the plain
  # non-setuid store binaries. With sw/bin first, `sudo` from an agent shell
  # resolves to the store copy and dies with "must be owned by uid 0 and have
  # the setuid bit set". Wrappers first = sudo works from agent shells
  # (xu-lax hard-won finding, preserved on extraction).
  agentPath =
    name: home:
    builtins.concatStringsSep ":" [
      "${home}/.local/bin"
      "${home}/.local/share/ucc/bin"
      "/etc/profiles/per-user/${name}/bin"
      "/run/wrappers/bin"
      "/run/current-system/sw/bin"
      "/nix/var/nix/profiles/default/bin"
    ];

  # config.json rendered into the store with the per-user ucc bin dir injected
  # in place of the consumer JSON's @UCC_BIN@ placeholder. The JSON source is
  # the consumer-supplied paseoConfigFile, so the flake owns the render
  # mechanism while each repo owns its own config content.
  # LEGACY path — used when paseoConfig is null and paseoConfigFile is set.
  renderPaseoConfig =
    name: home: configFile:
    agentLib.renderPaseoConfig {
      inherit name configFile;
      uccBinDir = "${home}/.local/share/ucc/bin";
    };

  # Dynamic path — generates config at daemon start from discovered wrappers.
  mkGenScript =
    name: home: pcfg:
    let
      uccBinDir = "${home}/.local/share/ucc/bin";
      baseConfigFile = agentLib.mkPaseoBaseConfig {
        inherit name;
        inherit (pcfg) listen relay features;
      };
    in
    agentLib.mkPaseoConfigGenScript {
      inherit name home uccBinDir baseConfigFile;
      inherit (pcfg) defaultLauncher providerOverrides;
    };
in
{
  options.osf.paseo = {
    enable = lib.mkEnableOption "paseo daemon for the configured users";

    paseoPackage = lib.mkOption {
      type = lib.types.package;
      default = paseoFlake.packages.${pkgs.stdenv.hostPlatform.system}.paseo;
      defaultText = lib.literalExpression "agent-flake's pinned paseo.packages.\${system}.paseo";
      description = ''
        Paseo package for the daemon + CLI. Defaults to the flake's central
        paseo pin. Override per-host (R2) for an outlier that needs a patched
        build, e.g. `pkgs.paseo-or-flake-pkg.overrideAttrs (…)` — without
        forcing that patch on the rest of the fleet.
      '';
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userOpts;
      default = { };
      description = "Users that get the paseo daemon. Key = existing system username.";
    };
  };

  config = lib.mkIf (cfg.enable && paseoUsers != { }) {
    systemd.services = lib.mapAttrs' (
      name: ucfg:
      let
        inherit (config.users.users.${name}) home;
        paseoHome = "${home}/.paseo";
        useDynamic = ucfg.paseoConfig != null;
        # Legacy: static config from file with @UCC_BIN@ substitution
        configJson = renderPaseoConfig name home ucfg.paseoConfigFile;
        # Dynamic: gen script discovers ucc-* wrappers at start
        genScript = mkGenScript name home ucfg.paseoConfig;
      in
      assert lib.assertMsg (useDynamic || ucfg.paseoConfigFile != null)
        "osf.paseo.users.${name}: set either paseoConfig (dynamic) or paseoConfigFile (legacy)";
      lib.nameValuePair "paseo-${name}" {
        description = "Paseo daemon for ${name} - self-hosted daemon for AI coding agents";
        after = [ "network-online.target" ]
          # Dynamic mode: wrappers must exist before gen script runs.
          ++ lib.optional useDynamic "ucc-update-${name}.service";
        wants = [ "network-online.target" ]
          ++ lib.optional useDynamic "ucc-update-${name}.service";
        requires = lib.optional useDynamic "ucc-update-${name}.service";
        wantedBy = [ "multi-user.target" ];

        # Clean restart (fleet stability). paseo runs its agents as DIRECT
        # CHILD PROCESSES in this unit's cgroup — there is no session reattach
        # (upstream 0.1.96). So an agent that runs `nixos-rebuild switch` from
        # inside paseo would, by systemd default (restartIfChanged=true,
        # KillMode=control-group), watch the switch SIGTERM the whole cgroup and
        # kill itself + its in-flight rebuild. Decouple the daemon restart from
        # the switch: a switch activates the new generation but leaves the
        # RUNNING daemon (and its agents) untouched. The new paseo version /
        # config.json applies on the next DELIBERATE restart (when no session is
        # mid-flight: `systemctl restart paseo-${name}`) or on reboot.
        # Crash-recovery is unaffected — `Restart = on-failure` still applies.
        restartIfChanged = false;
        stopIfChanged = false;

        environment = {
          NODE_ENV = "production";
          PASEO_HOME = paseoHome;
          # mkForce overrides the default PATH from NixOS's systemd module.
          PATH = lib.mkForce (agentPath name home);
        }
        // ucfg.environment;

        serviceConfig = {
          Type = "simple";
          User = name;

          ExecStartPre =
            # Password env file — rendered as root (+ prefix) before the daemon
            # starts, so sops secrets (typically root:root 0400) are readable.
            # systemd loads EnvironmentFile before ExecStart → PASEO_PASSWORD is
            # set in the daemon's environment; the daemon bcrypt-hashes it at boot.
            lib.optional (ucfg.passwordFile != null)
              "+${pkgs.writeShellScript "paseo-password-env-${name}" ''
                printf 'PASEO_PASSWORD=%s\n' "$(cat ${ucfg.passwordFile})" > /run/paseo-env-${name}
                chmod 600 /run/paseo-env-${name}
                chown ${name}: /run/paseo-env-${name}
              ''}"
            ++
            (if useDynamic then [
              # Dynamic: gen script scans wrappers → builds providers → writes config.json
              "${pkgs.coreutils}/bin/rm -f ${paseoHome}/config.json"
              "${genScript}"
            ] else [
              # Legacy: writable copy from the store-rendered static config.
              "${pkgs.coreutils}/bin/rm -f ${paseoHome}/config.json"
              "${pkgs.coreutils}/bin/install -D -m 0600 ${configJson} ${paseoHome}/config.json"
            ]);
          ExecStart = "${paseoPkg}/bin/paseo-server";

          Restart = "on-failure";
          RestartSec = 5;

          # Graceful shutdown (server handles SIGTERM with a 10s timeout)
          KillSignal = "SIGTERM";
          TimeoutStopSec = 15;
        }
        // lib.optionalAttrs (ucfg.passwordFile != null) {
          EnvironmentFile = [ "/run/paseo-env-${name}" ];
        };
      }
    ) paseoUsers;

    home-manager.users = lib.mapAttrs (_name: _ucfg: {
      # paseo CLI on the user's PATH (talks to the daemon).
      # config.json is no longer HM-managed — the systemd ExecStartPre install
      # (above) lays a writable copy, so HM drops its old read-only symlink.
      home.packages = [ paseoPkg ];
    }) paseoUsers;
  };
}
