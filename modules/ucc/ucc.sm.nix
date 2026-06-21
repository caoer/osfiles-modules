# modules/ucc/ucc.sm.nix — Foreign ucc installer (system-manager).
#
# Self-contained system-manager module for the UCC installer. Extracted from
# modules/system-manager/agent/{default,ucc}.nix.
#
# Version-gated ucc installer as a oneshot system-manager unit. The installer
# SCRIPT is the shared agentLib.mkInstallerScript (identical to the NixOS path);
# Foreign-specific wiring only: Debian-native deps on PATH (no nix-ld — Debian
# is a normal glibc distro, the downloaded node/ccc-statusd run natively),
# secrets read from the consumer-wired on-host paths, and a ConditionPathExists
# guard that keeps the unit green until the operator's post-activation secret
# push lands.
#
# What this module does NOT own (Foreign-specific; stays with the consumer):
#   - secret DELIVERY: the consumer declares its own foreign.secrets (which
#     sopsFile/key) and passes the resulting on-host paths here. The module
#     reads those paths; it never references the foreign.secrets option (which
#     lives in the consumer, not agent-flake).
#   - the HM layer (system prompt, codex, claude settings): the consumer
#     imports homeModules.ucc in its home.nix, like any host.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.uccForeign;
  agentLib = import ./lib.nix { inherit pkgs; };

  installerDeps = lib.makeBinPath (
    with pkgs;
    [
      curl
      bash
      coreutils
      gnutar
      gzip
      openssl
      gnugrep
      gnused
      gawk
      findutils
      git
    ]
  );
in
{
  options.osf.uccForeign = {
    enable = lib.mkEnableOption "Foreign (system-manager) UCC installer";

    username = lib.mkOption {
      type = lib.types.str;
      description = "Existing system username that owns the UCC installer unit.";
    };

    homeDirectory = lib.mkOption {
      type = lib.types.str;
      description = "Absolute home directory of `username` on the target host.";
    };

    uccVersion = lib.mkOption {
      type = lib.types.str;
      default = agentLib.defaultUccVersion;
      defaultText = lib.literalExpression "agent-flake's central defaultUccVersion (modules/ucc/lib.nix)";
      description = ''
        Desired ccc-statusd version. Shares the fleet-wide central default with
        the NixOS module (modules/ucc/lib.nix). Bump → deploy → installer
        re-runs (nix as updater); same version → skips in <1s.
      '';
    };

    uccUser = lib.mkOption {
      type = lib.types.str;
      description = "UCC installer user identity (combined with token to form URL).";
    };

    installerTokenPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/secrets/ucc_token";
      description = "On-host path where the consumer's secret delivery places the per-user UCC installer token.";
    };

    encryptionPasswordPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/secrets/ucc_encryption_password";
      description = "On-host path where the consumer's secret delivery places the UCC ENCRYPTION_PASSWORD.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.ucc-update = {
      description = "UCC installer (version-gated)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Stay green until the operator pushes the secrets post-activation; the
      # consumer's push-secrets path restarts this unit once they land.
      unitConfig.ConditionPathExists = [
        cfg.installerTokenPath
        cfg.encryptionPasswordPath
      ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.username;
        Environment = [ "PATH=${installerDeps}:/usr/local/bin:/usr/bin:/bin" ];
        ExecStart = agentLib.mkInstallerScript {
          name = cfg.username;
          inherit (cfg) uccUser;
          version = cfg.uccVersion;
          home = cfg.homeDirectory;
          tokenSecretPath = cfg.installerTokenPath;
          passwordSecretPath = cfg.encryptionPasswordPath;
        };
        RemainAfterExit = true;
      };
    };
  };
}
