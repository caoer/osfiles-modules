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
        type = lib.types.path;
        # REQUIRED — no default (R3). Each consumer supplies its OWN paseo
        # config JSON (relay endpoint, providers, daemon.listen port are all
        # consumer-specific). Leaving it unset fails loud at eval ("option …
        # paseoConfigFile is used but not defined") rather than silently
        # inheriting another consumer's relay/providers. The module owns the
        # render mechanism (@UCC_BIN@ → ucc bin dir); the consumer owns the JSON.
        description = ''
          Path to this user's paseo config JSON (with the @UCC_BIN@
          placeholder). REQUIRED when enable. The module renders it
          into the store and paseo.nixos.nix installs a writable copy at
          ~/.paseo/config.json on every daemon start.
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
  # the consumer-supplied paseoConfigFile (REQUIRED), so the flake owns the
  # render mechanism while each repo owns its own config content.
  renderPaseoConfig =
    name: home: configFile:
    agentLib.renderPaseoConfig {
      inherit name configFile;
      uccBinDir = "${home}/.local/share/ucc/bin";
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
        configJson = renderPaseoConfig name home ucfg.paseoConfigFile;
      in
      lib.nameValuePair "paseo-${name}" {
        description = "Paseo daemon for ${name} - self-hosted daemon for AI coding agents";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
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

          # Writable config.json. paseo's onboard / config-save writeFileSync's
          # to this path; a read-only store symlink would EROFS-crash it.
          ExecStartPre = [
            # migration + idempotence: drop any stale read-only HM symlink so
            # `install` cannot write THROUGH it into the read-only store (that
            # re-creates the EROFS).
            "${pkgs.coreutils}/bin/rm -f ${paseoHome}/config.json"
            # writable copy from the store — re-laid on every start, declarative wins.
            "${pkgs.coreutils}/bin/install -D -m 0600 ${configJson} ${paseoHome}/config.json"
          ];
          ExecStart = "${paseoPkg}/bin/paseo-server";

          Restart = "on-failure";
          RestartSec = 5;

          # Graceful shutdown (server handles SIGTERM with a 10s timeout)
          KillSignal = "SIGTERM";
          TimeoutStopSec = 15;
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
