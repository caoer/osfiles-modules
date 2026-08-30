# modules/moshi/moshi.nixos.nix — NixOS module for the Moshi host daemon.
#
# Moshi (https://getmoshi.app) is an iOS terminal app that attaches to a host
# over SSH/Mosh/ET and surfaces coding-agent activity — approvals, task
# completion, a diff viewer — in a native phone UI. This module runs the host
# half: the `moshi-hook serve` daemon.
#
# What the daemon does:
#   - listens on a Unix socket that agent hooks connect to;
#   - holds an OUTBOUND WebSocket to Moshi's cloud so the phone can answer
#     approvals (this is the product's design — approval round-trips leave the
#     host; shells, repos, and agent processes do not);
#   - serves a localhost-only HTTP gateway (default 127.0.0.1:24543) for the
#     diff viewer and transcript streaming, which the phone reaches through an
#     SSH local forward. Nothing binds a public interface, so this module
#     opens NO firewall ports on its own.
#
# The agent-hook side is deliberately NOT here — for UCC hosts it belongs to
# osf.ucc.users.<n>.moshi.enable, which generates the Claude hook entries in
# nix. See modules/ucc/ucc.nixos.nix for why the vendor's `moshi-hook install`
# cannot be used against UCC profiles.
#
# Consumer requirements: `pkgs` and the home-manager NixOS module.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.moshi;

  userOpts = lib.types.submodule (_: {
    options = {
      gatewayListen = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:24543";
        description = ''
          Listen address for the local diff/transcript gateway. Keep it on
          loopback — the phone is expected to reach it through an SSH local
          forward, and the gateway has NO bearer auth of its own.
        '';
      };
      extraEnvironment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          MOSHI_HERDR_PATH = "/home/zt/.local/bin/herdr";
        };
        description = ''
          Extra environment for the daemon. MOSHI_HERDR_PATH is the common one:
          the daemon reads herdr panes for terminal context and cannot always
          resolve the binary from a service PATH.
        '';
      };
    };
  });

  # Tools the daemon shells out to: tmux/zellij for pane context, git for the
  # diff viewer, ss/lsof for the local-server discovery that powers the app's
  # "open my dev server" flow.
  daemonPath = lib.makeBinPath (
    with pkgs;
    [
      coreutils
      git
      gnugrep
      iproute2
      lsof
      openssh
      procps
      tmux
    ]
  );
in
{
  options.osf.moshi = {
    enable = lib.mkEnableOption "Moshi host daemon (moshi-hook serve) for the configured users";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/moshi-hook.nix { };
      defaultText = lib.literalExpression "osf-modules' pinned packages/moshi-hook.nix";
      description = "moshi-hook package. One fleet version, bumped centrally in packages/moshi-hook.nix.";
    };

    mosh = {
      enable = lib.mkEnableOption ''
        Mosh transport for Moshi clients. OFF by default because turning it on
        OPENS INBOUND UDP 60000-61000 on this host — enabling "moshi" should
        not silently widen the network surface. SSH alone works; mosh buys
        roaming and survives the phone sleeping
      '';

      portRange = lib.mkOption {
        type = lib.types.attrsOf lib.types.port;
        default = {
          from = 60000;
          to = 61000;
        };
        description = ''
          UDP range opened for mosh-server when osf.moshi.mosh.enable is set.
          Narrow it if you know how many concurrent sessions you need — one
          port is consumed per live session.
        '';
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userOpts;
      default = { };
      description = "Users that run a Moshi daemon. Key = existing system username.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.users != { }) {
    environment.systemPackages = [ cfg.package ] ++ lib.optional cfg.mosh.enable pkgs.mosh;

    networking.firewall.allowedUDPPortRanges = lib.optional cfg.mosh.enable cfg.mosh.portRange;

    # The daemon is a systemd USER service, not a system service with User=.
    # The hook socket lives at $XDG_RUNTIME_DIR/moshi-hook.sock, and the user
    # manager gives that variable its correct per-user value (/run/user/<uid>)
    # for free. A system service with User= gets no XDG_RUNTIME_DIR at all, so
    # the daemon would bind a socket somewhere the hooks never look. Running
    # under the user manager is also what the vendor's own `service install`
    # does. linger keeps it up across logout and starts it at boot.
    users.users = lib.mapAttrs (_name: _ucfg: { linger = true; }) cfg.users;

    # Both ends resolve the socket the same way, and NEITHER may depend on the
    # session having XDG_RUNTIME_DIR. Measured on workstation-nyc-2: `zsh -l`
    # has it UNSET, so a hook spawned from a login shell falls back to the
    # vendor's /tmp/moshi-hook.sock default, finds nothing listening, and drops
    # the approval without an error anyone would see. Pin it explicitly:
    #   - daemon: %t, which systemd expands to the unit's runtime dir;
    #   - shells: the live uid, so it is right for every user without needing
    #     the uid at eval time.
    # shellInit is inlined into BOTH /etc/profile and /etc/zshenv, just below
    # the line where each sources /etc/set-environment — grep the two files,
    # not set-environment, when tracing where an export came from.
    # (/etc/profile.d/*.sh is NOT sourced by NixOS.)
    environment.shellInit = ''
      export MOSHI_SOCKET_PATH="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/moshi-hook.sock"
    '';

    home-manager.users = lib.mapAttrs (name: ucfg: {
      systemd.user.services.moshi-hook = {
        Unit = {
          Description = "Moshi host daemon for ${name} (hook socket + cloud bridge + diff gateway)";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };

        Service = {
          ExecStart = "${lib.getExe cfg.package} serve --gateway-listen ${ucfg.gatewayListen}";
          Restart = "on-failure";
          RestartSec = 5;
          Environment =
            [
              "PATH=${daemonPath}"
              # %t = this user unit's runtime dir (/run/user/<uid>). Matches
              # what the shells below compute, so daemon and hooks agree even
              # when a session never got XDG_RUNTIME_DIR.
              "MOSHI_SOCKET_PATH=%t/moshi-hook.sock"
            ]
            ++ lib.mapAttrsToList (k: v: "${k}=${v}") ucfg.extraEnvironment;
        };

        Install.WantedBy = [ "default.target" ];
      };
    }) cfg.users;

    # linger only guarantees the user manager runs; it does not create the
    # pairing. Pairing is inherently interactive — the token comes from the
    # Moshi app on the phone — and on a headless box the secret must go to a
    # file because there is no Keychain:
    #   moshi-hook pair --store file --token <token-from-app>
    # It lands in $XDG_STATE_HOME/moshi/secrets.json (0600) and survives
    # rebuilds. `moshi-hook status` reports whether this host is paired.
    warnings = lib.optional (!config.services.openssh.enable)
      "osf.moshi: sshd is disabled on this host, so Moshi clients have no way to attach (the gateway is loopback-only and reached over an SSH forward).";
  };
}
