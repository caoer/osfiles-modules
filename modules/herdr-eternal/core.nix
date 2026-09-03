# modules/herdr-eternal/core.nix — herdr-eternal-server: resumable
# transport for `herdr --remote` (Mic92/herdr-eternal). Core module, usable
# under NixOS and system-manager alike: options + the systemd unit, nothing
# else. herdr-eternal.nixos.nix wraps it with the package default and the
# firewall rule; system-manager hosts import this file by path
# ("''${osf-modules}/modules/herdr-eternal/core.nix").
#
# The mac (osfiles hosts/zmax) runs `herdr-eternal-ssh` as herdr's
# `[remote].ssh_command`; a target declared in its ~/.config/herdr-eternal/
# config.toml rides this unit instead of ssh. The exec channel runs herdr's
# remote bootstrap in `user`'s shell; `herdrPackage` installs the herdr the
# client expects (same version string) so that probe finds it in
# /run/current-system/sw/bin and never streams the binary over the channel —
# that stream stalls after ~10 MB on herdr-eternal 0.1.0.
#
# Listen on the host's mesh address only: plain ws:// then rides EasyTier's
# encryption and never touches LAN or WAN. Auth is a pre-shared token — one
# per host, the same value in the client's config.toml.
{
  config,
  lib,
  ...
}:
let
  cfg = config.osf.herdrEternal;
  home = if cfg.user == "root" then "/root" else "/home/${cfg.user}";
in
{
  options.osf.herdrEternal = {
    enable = lib.mkEnableOption "herdr-eternal-server (resumable herdr --remote transport)";

    package = lib.mkOption {
      type = lib.types.package;
      description = "herdr-eternal package providing bin/herdr-eternal-server.";
    };

    herdrPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        herdr installed system-wide and first on the unit PATH. Must report the
        version the client runs, or `herdr --remote` re-bootstraps over the
        exec channel.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "Account the exec channel runs as — the one `herdr --remote` lands in.";
    };

    listen = lib.mkOption {
      type = lib.types.str;
      example = "<mesh-ip>:7433";
      description = "addr:port for the WebSocket listener. Bind the mesh address, never the wildcard.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Pre-shared token file, readable by `user` (mode 0400).";
    };

    meshUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "easytier.service";
      description = "EasyTier unit that brings up the listen address; ordered after it.";
    };

    quic = {
      listen = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "<lan-ip>:24333";
        description = ''
          Optional QUIC listener (UDP, TLS terminated by the server itself). The
          way in for a client that cannot reach the mesh: bind an address behind
          a public DNAT and hand the client `quic_addr` + `quic_ca`.
        '';
      };
      certFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "PEM certificate for the QUIC listener (SAN = the address the client dials).";
      };
      keyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "PEM private key for the QUIC listener, readable by `user`.";
      };
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Directories prepended to the unit PATH (where herdr lives on this host).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.quic.listen == null || (cfg.quic.certFile != null && cfg.quic.keyFile != null);
        message = "osf.herdrEternal.quic: listen needs certFile and keyFile.";
      }
    ];

    environment.systemPackages = lib.optional (cfg.herdrPackage != null) cfg.herdrPackage;

    systemd.services.herdr-eternal-server = {
      description = "herdr-eternal-server — resumable transport for herdr --remote (${cfg.user})";
      after = [ "network-online.target" ] ++ lib.optional (cfg.meshUnit != null) cfg.meshUnit;
      wants = [ "network-online.target" ] ++ lib.optional (cfg.meshUnit != null) cfg.meshUnit;
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = cfg.tokenFile;

      serviceConfig = {
        Type = "notify";
        User = cfg.user;
        Environment = [
          "HOME=${home}"
          (
            "PATH="
            + lib.concatStringsSep ":" (
              lib.optional (cfg.herdrPackage != null) "${cfg.herdrPackage}/bin"
              ++ cfg.extraPath
              ++ [
                "${home}/.local/bin"
                "/etc/profiles/per-user/${cfg.user}/bin"
                "${home}/.nix-profile/bin"
                "/run/current-system/sw/bin"
                "/nix/var/nix/profiles/default/bin"
                "/usr/local/bin"
                "/usr/bin"
                "/bin"
              ]
            )
          )
        ];
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/herdr-eternal-server"
            "--listen ${cfg.listen}"
            "--token-file ${cfg.tokenFile}"
          ]
          ++ lib.optionals (cfg.quic.listen != null) [
            "--quic-listen ${cfg.quic.listen}"
            "--quic-cert ${cfg.quic.certFile}"
            "--quic-key ${cfg.quic.keyFile}"
          ]
        );
        # Agent socket + handed-over session state survive restarts.
        RuntimeDirectory = "herdr-eternal-server";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
        # Sessions outlive the daemon: children are not killed, their pipe
        # fds sit in the fd store for the next instance to reclaim.
        KillMode = "process";
        FileDescriptorStoreMax = 256;
        # bind fails until the mesh interface is up — keep retrying.
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
