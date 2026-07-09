# modules/paseo/paseo.sm.nix — Foreign paseo daemon (system-manager).
#
# Self-contained system-manager module for the paseo daemon. Extracted from
# modules/system-manager/agent/{default,paseo}.nix.
#
# The hand-rolled equivalent of the NixOS paseo unit, using only serviceConfig
# directives (no NixOS systemd-module conveniences). The paseo PACKAGE comes
# from osf.paseoForeign.paseoPackage (the flake pin by default); config.json is
# rendered via the shared agentLib.renderPaseoConfig and materialized as a
# WRITABLE copy by ExecStartPre — identical mechanics to the NixOS path: it is
# NOT a store symlink (paseo's onboard / config-save writeFileSync's the path,
# which EROFS-crashes a read-only store symlink). ExecStartPre first rm -f's any
# stale read-only HM symlink so `install` can't write THROUGH it back into the
# store, then installs the copy — silent mechanics, loud failure. Daemon identity
# (~/.paseo/server-id, daemon-keypair.json) is generated on first start and left
# alone — identity = host, back it up across reinstalls.
#
# Clean restart: system-manager honours serviceConfig."X-RestartIfChanged" in
# [Service] and SKIPS the unit restart on `system-manager switch`, so a switch
# triggered by an agent running INSIDE paseo doesn't kill the agent + its
# in-flight switch. New version/config applies on the next deliberate
# `systemctl restart paseo` or reboot. (The NixOS path uses restartIfChanged=false.)
#
# Factory form: `{ paseoFlake }: <module>` — paseo needs paseoFlake for the package.
{ paseoFlake }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.paseoForeign;
  agentLib = import ../ucc/lib.nix { inherit pkgs; };
  home = cfg.homeDirectory;
  paseoHome = "${home}/.paseo";

  configJson = agentLib.renderPaseoConfig {
    name = "foreign";
    uccBinDir = "${home}/.local/share/ucc/bin";
    configFile = cfg.paseoConfigFile;
  };

  # Foreign/Debian agent PATH: ucc-installed tools (~/.local/bin, ucc bin), the
  # HM toolchain (~/.nix-profile/bin: git, node, go…), nix default profile, then
  # Debian system paths. (The NixOS path uses /etc/profiles/per-user +
  # /run/wrappers + /run/current-system instead — those don't exist on Foreign.)
  agentPath = builtins.concatStringsSep ":" [
    "${home}/.local/bin"
    "${home}/.local/share/ucc/bin"
    "${home}/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];
in
{
  options.osf.paseoForeign = {
    enable = lib.mkEnableOption "Foreign (system-manager) paseo daemon";

    username = lib.mkOption {
      type = lib.types.str;
      description = "Existing system username that owns the paseo daemon unit.";
    };

    homeDirectory = lib.mkOption {
      type = lib.types.str;
      description = "Absolute home directory of `username` on the target host.";
    };

    paseoPackage = lib.mkOption {
      type = lib.types.package;
      default = paseoFlake.packages.${pkgs.stdenv.hostPlatform.system}.paseo;
      defaultText = lib.literalExpression "agent-flake's pinned paseo.packages.\${system}.paseo";
      description = ''
        Paseo package for the daemon + CLI. Defaults to the flake's central pin;
        override for a patched build (e.g. inputs.agent.packages.<system>.paseo-speech).
      '';
    };

    paseoConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        LEGACY: path to a static paseo config JSON (with @UCC_BIN@ placeholder).
        Rendered into the store with ucc bin dir injected, then installed as a
        writable copy. Mutually exclusive with paseoConfig — if paseoConfig is
        set, this is ignored.
      '';
    };

    paseoConfig = lib.mkOption {
      # Shared schema — ONE definition across nixos/sm/hm (agentLib).
      type = lib.types.nullOr (lib.types.submodule { options = agentLib.paseoConfigOptions lib; });
      default = null;
      description = ''
        Structured paseo config — dynamic provider discovery from ucc-*
        wrappers at daemon start. When set, replaces paseoConfigFile.
      '';
    };

    paseoListen = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:6767";
      description = "PASEO_LISTEN for the daemon (loopback by default — no daemon password needed).";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the plaintext paseo daemon password (e.g.
        a sops-nix or foreign.secrets path). Sets PASEO_PASSWORD env at daemon
        start — the daemon bcrypt-hashes it on boot. Required when listen is
        non-loopback.
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "CLAUDE_CONFIG_DIR=/home/cos-user/.local/share/ucc/shared" ];
      description = ''
        Extra systemd Environment= lines for the paseo daemon (and so every
        agent it spawns), e.g. a shared CLAUDE_CONFIG_DIR. A per-provider env in
        config.json does NOT propagate to agents — it must live on the unit.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    let
      useDynamic = cfg.paseoConfig != null;
      genScript = agentLib.mkPaseoConfigGenScript {
        name = "foreign";
        inherit home;
        uccBinDir = "${home}/.local/share/ucc/bin";
        baseConfigFile = agentLib.mkPaseoBaseConfig {
          name = "foreign";
          inherit (cfg.paseoConfig) listen relay features browserTools enableTerminalAgentHooks autoArchiveAfterMerge authPasswordHash;
        };
        inherit (cfg.paseoConfig) defaultLauncher providerOverrides profilePresets;
      };
    in
    assert lib.assertMsg (useDynamic || cfg.paseoConfigFile != null)
      "osf.paseoForeign: set either paseoConfig (dynamic) or paseoConfigFile (legacy)";
    {
      systemd.services.paseo = {
        description = "Paseo - self-hosted daemon for AI coding agents";
        after = [ "network-online.target" ]
          ++ lib.optional useDynamic "ucc-update.service";
        wants = [ "network-online.target" ]
          ++ lib.optional useDynamic "ucc-update.service";
        requires = lib.optional useDynamic "ucc-update.service";
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          User = cfg.username;

          Environment = [
            "NODE_ENV=production"
            "PASEO_HOME=${paseoHome}"
            "PASEO_LISTEN=${cfg.paseoListen}"
            "PATH=${agentPath}"
            # Shared ucc config dir — lets paseo agents read session history.
            "CLAUDE_CONFIG_DIR=${home}/.local/share/ucc/shared"
            # Explicit UCC_HOME: ccc-injection builds its log dir from it.
            # Without it, bundles < c632921 hit a HOME+"./local" typo fallback
            # → EACCES mkdir /home/<user>. spam on Agent SDK stderr.
            "UCC_HOME=${home}/.local/share/ucc"
          ]
          ++ cfg.extraEnvironment;

          ExecStartPre =
            # Password env file — rendered as root (+ prefix) so sops/foreign
            # secrets (typically root:root 0400) are readable. systemd loads
            # EnvironmentFile before ExecStart → PASEO_PASSWORD set in daemon env.
            lib.optional (cfg.passwordFile != null)
              "+${pkgs.writeShellScript "paseo-password-env-foreign" ''
                printf 'PASEO_PASSWORD=%s\n' "$(cat ${cfg.passwordFile})" > /run/paseo-env-foreign
                chmod 600 /run/paseo-env-foreign
                chown ${cfg.username}: /run/paseo-env-foreign
              ''}"
            ++
            (if useDynamic then [
              "${pkgs.coreutils}/bin/rm -f ${paseoHome}/config.json"
              "${genScript}"
            ] else [
              "${pkgs.coreutils}/bin/rm -f ${paseoHome}/config.json"
              "${pkgs.coreutils}/bin/install -D -m 0600 ${configJson} ${paseoHome}/config.json"
            ]);
          ExecStart = "${cfg.paseoPackage}/bin/paseo-server";

          # Clean restart — system-manager honours this raw [Service] directive.
          "X-RestartIfChanged" = "false";

          Restart = "on-failure";
          RestartSec = 5;
          KillSignal = "SIGTERM";
          TimeoutStopSec = 15;
        }
        // lib.optionalAttrs (cfg.passwordFile != null) {
          EnvironmentFile = [ "/run/paseo-env-foreign" ];
        };
      };
    }
  );
}
