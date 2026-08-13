# modules/agent/agent.nixos.nix — convenience profile that turns on the agent
# stack (osf.ucc + osf.paseo) with fleet defaults.
#
# The real modules live in modules/ucc and modules/paseo; this is just a
# one-shot enable + defaults so consumers don't copy-paste the same block.
#
#   osf.agent = {
#     enable = true;
#     users.caoer115 = {
#       uccUser = "zitao";
#       # optional: encryptionPasswordSopsFile = ./secrets/hosts/foo.sops.yaml;
#     };
#   };
#
# Fleet upgrades:
#   ucc                — get-ucc.sui.pics latest (no nix pin; restart ucc-update)
#   paseo pin          — flake.nix inputs.paseo
#   herdr / grok       — consumer-owned (osfiles home/linux/*); not here
{
  config,
  lib,
  ...
}:
let
  cfg = config.osf.agent;
  host = config.networking.hostName;

  userOpts = lib.types.submodule (_: {
    options = {
      uccUser = lib.mkOption {
        type = lib.types.str;
        description = "UCC installer user identity (combined with token for URL).";
      };
      installerTokenSecret = lib.mkOption {
        type = lib.types.str;
        default = "ucc_token";
        description = "sops secret name holding the UCC installer token.";
      };
      encryptionPasswordSecret = lib.mkOption {
        type = lib.types.str;
        default = "ucc_encryption_password";
        description = "sops secret name holding ENCRYPTION_PASSWORD.";
      };
      encryptionPasswordSopsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Optional override for the sops file holding the encryption password.
          null → module default (osf-modules secrets/ucc.yaml). Set to the
          host sops file when the host is not a recipient of that central file.
        '';
      };
      paseoHostnames = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          PASEO_HOSTNAMES for the daemon. null → ".''${networking.hostName}".
        '';
      };
    };
  });
in
{
  options.osf.agent = {
    enable = lib.mkEnableOption "AI agent stack (ucc + paseo) with fleet defaults";

    users = lib.mkOption {
      type = lib.types.attrsOf userOpts;
      default = { };
      description = "Users that get ucc + paseo. Key = system username.";
    };

    relay = {
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "paseo.0xtau.com:443";
        description = "Paseo relay endpoint.";
      };
      useTls = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use TLS for the paseo relay.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.users != { }) {
    osf.ucc = {
      enable = true;
      users = lib.mapAttrs (
        _name: ucfg:
        {
          inherit (ucfg) uccUser installerTokenSecret encryptionPasswordSecret;
        }
        // lib.optionalAttrs (ucfg.encryptionPasswordSopsFile != null) {
          encryptionPasswordSopsFile = ucfg.encryptionPasswordSopsFile;
        }
      ) cfg.users;
    };

    osf.paseo = {
      enable = true;
      users = lib.mapAttrs (_name: ucfg: {
        paseoConfig = {
          relay = {
            enabled = true;
            inherit (cfg.relay) endpoint useTls;
          };
        };
        environment.PASEO_HOSTNAMES =
          if ucfg.paseoHostnames != null then ucfg.paseoHostnames else ".${host}";
      }) cfg.users;
    };
  };
}
