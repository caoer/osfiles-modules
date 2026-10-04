# modules/ucc/ucc.nixos.nix — NixOS UCC + Claude Code profile module.
#
# Self-contained NixOS module for UCC (ccc-statusd + Claude Code profiles).
# Extracted from modules/nixos/agent/{default,ucc}.nix. Per user:
#   ucc-update-<user>          UCC installer (always latest from
#                              get-ucc.sui.pics; the installer skips artifacts
#                              that already match the published release)
#   agent-claude-settings-<user>  syncs the nix-defined settings.json (+
#                              .claude.json patch) into every UCC profile —
#                              the declarative "claude code profile config"
#                              (preset-activate pattern from locus
#                              wiki/outbox/presets.nix)
#   ~/.local/bin/claude        → ~/.local/share/ucc/bin/ucc-auto
#   ~/.local/share/ucc/shared/SYSTEM_PROMPT.md
#                              → flake-canonical store copy by default
#                              (osf.ucc.users.<n>.systemPromptSource). No ucc
#                              launcher reads it; ucc-auto takes its system
#                              prompt from its launch pages. A string
#                              source switches it to a live-edit symlink.
#   ~/.local/share/ucc/shared/CLAUDE.md
#                              → the target every profiles/<n>/CLAUDE.md
#                              symlinks to (osf.ucc.users.<n>.claudeMdSource).
#                              UNMANAGED by default — a host opts in. The ucc
#                              installer only makes the links and treats a
#                              dangling one as valid, so without this nothing
#                              provisions the file and agents load no
#                              user-scope layer.
#   codex CLI (flake-pinned)   when codex.enable (paseo's native provider)
#   ENCRYPTION_PASSWORD        exported into that user's shells from the sops
#                              secret — the env `ucc-cli update` demands when
#                              the user runs it by hand
#
# Multi-user: each user gets ucc-update-<user>, agent-claude-settings-<user>
# units. On a multi-user host, set distinct sops secret names
# (installerTokenSecret/encryptionPasswordSecret) per user.
#
# Consumer requirements: provides `pkgs`, sops-nix, and the home-manager NixOS
# module (wires `home-manager.users`). Guarded by osf.ucc.enable.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.osf.ucc;
  homeOf = name: config.users.users.${name}.home;

  # Shared installer/render builders — same source the Foreign system-manager
  # module uses, so both platforms run byte-identical ucc-installer logic.
  agentLib = import ./lib.nix { inherit pkgs; };

  userOpts = lib.types.submodule (_: {
    options = {
      systemPromptSource = lib.mkOption {
        type = lib.types.either lib.types.path lib.types.str;
        default = ../../assets/SYSTEM_PROMPT.md;
        defaultText = lib.literalExpression "agent-flake's canonical assets/SYSTEM_PROMPT.md (immutable store copy)";
        description = ''
          File placed at ~/.local/share/ucc/shared/SYSTEM_PROMPT.md. No ucc
          launcher reads it (ucc-auto passes no --system-prompt-file). Defaults to
          agent-flake's canonical prompt as a nix PATH → an immutable store copy,
          so the fleet stays uniform (rebuild to change). Per-host ESCAPE HATCH:
          set a STRING absolute path (e.g.
          "''${config.osf.ucc.repoRoot}/config/agent/SYSTEM_PROMPT.md") for an
          out-of-store live-edit symlink, or another nix path for a different
          store copy.
        '';
      };
      claudeMdSource = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
        default = null;
        description = ''
          User-scope CLAUDE.md → ~/.local/share/ucc/shared/CLAUDE.md, the file
          every profile's CLAUDE.md symlinks to. Defaults to null = UNMANAGED:
          a host opts in explicitly, so enabling the option fleet-wide changes
          nothing until a host names a source.

          The ucc installer creates profiles/<n>/CLAUDE.md ->
          ../../shared/CLAUDE.md unconditionally and treats a dangling link as
          valid, so it never provisions the target; nothing else did either.
          A host with no writer serves every agent an empty user-scope layer
          while looking correctly installed.

          Set a STRING absolute path (e.g.
          "''${config.osf.ucc.repoRoot}/config/ucc/CLAUDE.md") for an
          out-of-store live-edit symlink, or a nix path for a store copy.
          Only set this where nothing else writes that path.
        '';
      };
      uccUser = lib.mkOption {
        type = lib.types.str;
        description = ''
          UCC installer user identity. Combined with the token to form
          the installer URL. Not a secret — just an identifier.
        '';
      };
      bootFetch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether ucc-update-<user> fetches the UCC release at boot. Set
          false on a host whose image carries UCC: every user there still
          runs UCC as the one shared identity, which rides in the image, so
          the boot-time fetch is off (ucc-update-<user> is masked), the
          per-owner copies of the token and the encryption password are not
          declared as sops secrets, and ENCRYPTION_PASSWORD is not exported
          into the user's shells. The settings sync and the home layer are
          the same either way.
        '';
      };
      daemonUserUnit = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run this user's ccc-statusd in a systemd user unit (ccc-statusd.service)
          under a lingering user manager, and have ucc-update-<user> hand the
          daemon to that unit around the installer. Off: the installer starts
          the daemon itself, inside ucc-update-<user>'s cgroup, where stopping
          or restarting that unit kills it. Turning it on sets linger (a user
          manager from boot) and declares the user unit; a host that declares
          its own ccc-statusd user unit leaves this off. Needs bootFetch.
        '';
      };
      installerTokenSecret = lib.mkOption {
        type = lib.types.str;
        default = "ucc_token";
        description = ''
          sops secret name (in the host's defaultSopsFile) holding the
          per-user UCC installer token. Give each user on a multi-user
          host their own key name.
        '';
      };
      encryptionPasswordSecret = lib.mkOption {
        type = lib.types.str;
        default = "ucc_encryption_password";
        description = ''
          sops secret name holding the UCC ENCRYPTION_PASSWORD. Shared
          across hosts — decrypted from the centralized secrets/ucc.yaml
          in osf-modules by default.
        '';
      };
      encryptionPasswordSopsFile = lib.mkOption {
        type = lib.types.path;
        default = ../../secrets/ucc.yaml;
        defaultText = lib.literalExpression "osf-modules's secrets/ucc.yaml";
        description = ''
          Path to the sops-encrypted file containing the UCC encryption
          password. Defaults to the centralized secrets/ucc.yaml shipped
          with osf-modules (all UCC hosts listed in its .sops.yaml).
          Override per-host if the host's key isn't in osf-modules yet.
        '';
      };
      claudeSettings = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Per-user overrides recursively merged over the module's base
          overrides (baseClaudeSettings: model, effort, plugins).
          agent-claude-settings-<user> deep-merges the result onto every UCC
          profile's settings.json and then runs the daemon's `config generate`,
          so the installer's policy stays on top. Never declare a key the
          installer forces (theme, tui, askUserQuestionTimeout, permissions
          mode, timeout env) nor `hooks` / `statusLine` — those flip on
          alternating runs (lib.nix mkSettingsSyncScript).
        '';
      };
      codex.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install the OpenAI codex CLI (nixpkgs) for this user (paseo's native codex provider drives it).";
      };
    };
  });

  # --- Claude Code profile settings: the OVERRIDES nix adds on top of what the
  # installer writes. The policy, the daemon's hooks and statusLine are the
  # installer's (lib.nix mkSettingsSyncScript). ---

  baseClaudeSettings =
    name:
    let
      uccData = "${homeOf name}/.local/share/ucc";
    in
    {
      env = {
        CLAUDE_CODE_SCROLL_SPEED = "10";
      };
      enabledPlugins = {
        "agent-skills@addy-agent-skills" = false;
        "coding-tutor@compound-engineering-plugin" = false;
        "compound-engineering@compound-engineering-plugin" = false;
      };
      extraKnownMarketplaces = {
        "addy-agent-skills" = {
          source = {
            source = "file";
            path = "${uccData}/shared/marketplaces/agent-skills/.claude-plugin/marketplace.json";
          };
        };
        "compound-engineering-plugin" = {
          source = {
            source = "file";
            path = "${uccData}/shared/marketplaces/compound-engineering-plugin/.claude-plugin/marketplace.json";
          };
        };
      };
      autoMemoryEnabled = true;
      effortLevel = "medium";
      verbose = false;
      model = "claude-opus-5-5[1m]";
      enableWorkflows = false;
      workflowKeywordTriggerEnabled = false;
    };

  # --- UCC installer — shared builder (modules/ucc/lib.nix). The NixOS and
  # Foreign paths run identical logic; only secret wiring differs (sops-nix
  # paths here, foreign.secrets paths on Foreign). ---
  mkInstallerScript =
    name: ucfg:
    agentLib.mkInstallerScript {
      inherit name;
      inherit (ucfg) uccUser;
      home = homeOf name;
      tokenSecretPath = config.sops.secrets.${ucfg.installerTokenSecret}.path;
      passwordSecretPath = config.sops.secrets.${ucfg.encryptionPasswordSecret}.path;
    };

  # --- settings sync: the overrides onto every profile, the daemon's policy on
  # top (lib.nix mkSettingsSyncScript) ---
  mkSettingsSyncScript =
    name: ucfg:
    agentLib.mkSettingsSyncScript {
      inherit name;
      home = homeOf name;
      settingsFile = pkgs.writeText "agent-claude-settings-${name}.json" (
        builtins.toJSON (lib.recursiveUpdate (baseClaudeSettings name) ucfg.claudeSettings)
      );
    };

  # Downloaded binaries (node, ccc-statusd) are dynamically linked; nix-ld
  # resolves them through these two variables.
  nixLdEnvironment = {
    NIX_LD = "${pkgs.glibc}/lib/ld-linux-x86-64.so.2";
    NIX_LD_LIBRARY_PATH = lib.makeLibraryPath [
      pkgs.stdenv.cc.cc.lib
      pkgs.glibc
      pkgs.zlib
    ];
  };

  installerPackages = with pkgs; [
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
    # ps: the installer reads the resident engine's command with
    # `ps -p <pid> -o command=` and restarts it only when that read
    # names the installed mrd; without ps it skips the restart silently.
    procps
    # cmp: the installer compares the downloaded mrd with the installed one.
    diffutils
  ];

  installerUnits = lib.mapAttrs' (
    name: ucfg:
    lib.nameValuePair "ucc-update-${name}" (
      {
        description = "UCC installer for ${name} (latest release)";
        after = [
          "sops-nix.service"
          "network-online.target"
        ]
        ++ lib.optional (daemonInUserUnit name ucfg) "home-manager-${utils.escapeSystemdPath name}.service";
        wants = [
          "sops-nix.service"
          "network-online.target"
        ];
        wantedBy = [ "multi-user.target" ];
        path = installerPackages;
        environment = nixLdEnvironment;
        enable = ucfg.bootFetch;
        serviceConfig = {
          Type = "oneshot";
          User = name;
          RemainAfterExit = true;
        }
        // lib.optionalAttrs ucfg.bootFetch {
          # Opted-in accounts run the installer itself under the lingering user
          # manager. Every process it starts then inherits a user cgroup instead
          # of ucc-update-<user>.service, so stopping or restarting this system
          # unit cannot kill a resident mrd (or another detached helper).
          ExecStart =
            if daemonInUserUnit name ucfg then installerThroughUserUnit name else mkInstallerScript name ucfg;
        }
        // lib.optionalAttrs (daemonInUserUnit name ucfg) {
          ExecStartPre = daemonToUserUnit "pre";
          ExecStartPost = daemonToUserUnit "post";
        };
      }
      // lib.optionalAttrs (daemonInUserUnit name ucfg) {
        restartTriggers = [ (mkInstallerScript name ucfg) ];
      }
    )
  ) cfg.users;

  # Opted-in accounts only (daemonUserUnit). An explicit linger = false wins
  # over the option's default and also turns the unit and the handoff off, so
  # nothing waits at boot for a user manager that never starts.
  daemonInUserUnit =
    name: ucfg: ucfg.bootFetch && ucfg.daemonUserUnit && config.users.users.${name}.linger != false;

  # The daemon belongs to the user's manager, in the ccc-statusd user unit
  # below — never to this system unit. "pre" starts the user unit so the
  # installer finds the daemon there; "post" replaces a daemon the installer
  # started outside that unit (first install, user manager late). These handoff
  # hooks stay non-fatal, while installerThroughUserUnit below fails loudly if
  # the user manager is unreachable rather than running the installer in the
  # unsafe system-unit cgroup.
  daemonToUserUnit =
    phase:
    pkgs.writeShellScript "ucc-daemon-user-unit-${phase}" ''
      set -u
      export XDG_RUNTIME_DIR="/run/user/$(id -u)"
      # The daemon's pidfile lives in CCC_CACHE_DIR when the UCC env chain
      # sets it — the same files the user unit sources before the daemon.
      cache=$(
        set +eu
        for f in default-env.sh user-env.sh user-override.sh; do
          [ -f "$HOME/.local/share/ucc/$f" ] && . "$HOME/.local/share/ucc/$f" >/dev/null 2>&1
        done
        printf '%s' "''${CCC_CACHE_DIR:-$HOME/.local/share/ucc/cache/ccc-status}"
      )
      pidfile="$cache/daemon.pid"
      owned() {
        main=$(systemctl --user show -p MainPID --value ccc-statusd.service 2>/dev/null || true)
        pid=$(tr -dc '0-9' < "$pidfile" 2>/dev/null || true)
        [ -n "$pid" ] && [ "$main" = "$pid" ]
      }
      # Linger starts the manager at boot; pre waits for it, post does not.
      if [ ${phase} = pre ]; then
        for _ in $(seq 30); do
          systemctl --user show-environment >/dev/null 2>&1 && break
          sleep 2
        done
      fi
      if ! systemctl --user show-environment >/dev/null 2>&1; then
        echo "ucc: user manager unreachable — the daemon stays where the installer starts it" >&2
        exit 0
      fi
      [ -x "$HOME/.local/bin/ccc-statusd" ] || exit 0
      if [ ${phase} = pre ]; then
        systemctl --user start ccc-statusd.service || exit 0
      elif ! owned; then
        echo "ucc: daemon is outside ccc-statusd.service — restarting it through the unit"
        systemctl --user restart ccc-statusd.service || exit 0
      fi
      for _ in $(seq 30); do
        owned && { echo "ucc: daemon $pid runs in ccc-statusd.service (${phase})"; exit 0; }
        sleep 1
      done
      echo "ucc: ccc-statusd.service does not own the daemon after 30s (${phase})" >&2
      exit 0
    '';

  # The system boot unit remains the trigger and waits for the user unit's
  # result, but it is no longer the installer's cgroup parent. The pre hook has
  # already waited for the lingering manager, so failure here is loud rather
  # than falling back to the unsafe system-unit cgroup.
  installerThroughUserUnit =
    name:
    pkgs.writeShellScript "ucc-installer-through-user-unit-${name}" ''
      set -eu
      export XDG_RUNTIME_DIR="/run/user/$(id -u)"
      exec systemctl --user start --wait ucc-update.service
    '';

  # A oneshot normally cleans up every descendant when its main process exits.
  # KillMode=process deliberately leaves detached installer children in this
  # user cgroup: mrd has no foreground supervisor or stop verb, and the UCC
  # installer owns its pidfile-targeted restart. A later run reuses the unit;
  # stopping the system ucc-update-<user> trigger never reaches this cgroup.
  installerUserUnit =
    name: ucfg:
    let
      home = homeOf name;
      unitPath = lib.concatStringsSep ":" [
        (lib.makeBinPath installerPackages)
        "${home}/.local/bin"
        "${home}/.local/share/ucc/bin"
        "/run/wrappers/bin"
        "/etc/profiles/per-user/${name}/bin"
        "/run/current-system/sw/bin"
      ];
    in
    {
      Unit.Description = "UCC installer for ${name} (user cgroup)";
      Service = {
        Type = "oneshot";
        ExecStart = mkInstallerScript name ucfg;
        KillMode = "process";
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") (nixLdEnvironment // { PATH = unitPath; });
      };
    };

  # The daemon's home: one user unit per opted-in user, run by its lingering
  # user manager so it starts at boot with no login.
  daemonUserUnit =
    name:
    let
      home = homeOf name;
      unitPath = lib.concatStringsSep ":" [
        "${home}/.local/bin"
        "${home}/.local/share/ucc/bin"
        "/run/wrappers/bin"
        "/etc/profiles/per-user/${name}/bin"
        "/run/current-system/sw/bin"
      ];
    in
    {
      Unit = {
        Description = "ccc-statusd daemon for ${name}";
        # The Environment below names nixpkgs store paths, so every nixpkgs
        # bump changes the unit; keep-old leaves the running daemon to the
        # installer, which restarts it through this unit on a new release.
        X-SwitchMethod = "keep-old";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        ConditionPathExists = "%h/.local/bin/ccc-statusd";
      };
      Service = {
        # A daemon started outside the unit (a shell, a hook) holds the
        # socket; stop reclaims it.
        ExecStartPre = "-%h/.local/bin/ccc-statusd stop";
        ExecStart = "${pkgs.bash}/bin/bash -c 'for f in default-env.sh user-env.sh user-override.sh; do [ -f %h/.local/share/ucc/$$f ] && . %h/.local/share/ucc/$$f; done; exec %h/.local/bin/ccc-statusd start --foreground'";
        Restart = "always";
        RestartSec = 5;
        Environment = lib.mapAttrsToList (k: v: "${k}=${v}") (nixLdEnvironment // { PATH = unitPath; });
      };
      Install.WantedBy = [ "default.target" ];
    };

  settingsUnits = lib.mapAttrs' (
    name: ucfg:
    lib.nameValuePair "agent-claude-settings-${name}" {
      description = "Sync nix-defined Claude Code settings into UCC profiles for ${name}";
      after = [ "ucc-update-${name}.service" ];
      wants = [ "ucc-update-${name}.service" ];
      wantedBy = [ "multi-user.target" ];
      # The sync script runs the downloaded ccc-statusd (dynamically linked).
      environment = nixLdEnvironment;
      serviceConfig = {
        Type = "oneshot";
        User = name;
        ExecStart = mkSettingsSyncScript name ucfg;
        RemainAfterExit = true;
      };
    }
  ) cfg.users;
in
{
  options.osf.ucc = {
    enable = lib.mkEnableOption "UCC agent profile (ccc-statusd + Claude Code) for the configured users";

    repoRoot = lib.mkOption {
      type = lib.types.str;
      default = config.osf.repoRoot;
      description = ''
        osfiles/consumer checkout root ON THE TARGET HOST. The system prompt
        out-of-store symlink target resolves under it. Defaults to
        `config.osf.repoRoot` for the osfiles consumer; consumers without
        that option MUST set this.
      '';
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userOpts;
      default = { };
      description = "Users that get the UCC agent profile. Key = existing system username.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.users != { }) {
    # Downloaded binaries (node, ccc-statusd) are dynamically linked.
    programs.nix-ld.enable = true;

    # NOTE: on a multi-user host, give each user distinct secret names —
    # one sops.secrets entry can only have one owner.
    sops.secrets = lib.mkMerge (
      lib.mapAttrsToList (
        name: ucfg:
        lib.optionalAttrs ucfg.bootFetch {
          ${ucfg.installerTokenSecret} = {
            mode = "0400";
            owner = name;
          };
          ${ucfg.encryptionPasswordSecret} = {
            mode = "0400";
            owner = name;
            # Centralized in osf-modules — all UCC hosts listed in .sops.yaml.
            # Override per-host with osf.ucc.users.<n>.encryptionPasswordSopsFile.
            sopsFile = ucfg.encryptionPasswordSopsFile;
          };
        }
      ) cfg.users
    );

    systemd.services = installerUnits // settingsUnits;

    # `ucc-cli update` run by hand refuses without ENCRYPTION_PASSWORD ("Error:
    # ENCRYPTION_PASSWORD is required."). ucc-update-<user> reads the secret off
    # disk itself, so only the interactive path was missing it — every UCC host
    # had a user who could not update their own install.
    #
    # Per-user guard: each secret is mode 0400 owned by its user, so a shell
    # belonging to anyone else reads nothing and exports nothing.
    # shellInit is inlined into BOTH /etc/profile and /etc/zshenv, just below
    # the line where each sources /etc/set-environment — grep the two files,
    # not set-environment, when tracing where an export came from. /etc/zshenv
    # runs for every zsh, so a non-login shell gets it too.
    # (/etc/profile.d/*.sh is NOT sourced by NixOS.)
    environment.shellInit = lib.concatStrings (
      lib.mapAttrsToList (
        name: ucfg:
        let
          passwordPath = config.sops.secrets.${ucfg.encryptionPasswordSecret}.path;
        in
        lib.optionalString ucfg.bootFetch ''
          if [ "$(id -un 2>/dev/null)" = "${name}" ] && [ -r ${passwordPath} ]; then
            export ENCRYPTION_PASSWORD="$(cat ${passwordPath})"
          fi
        ''
      ) cfg.users
    );

    # daemonUserUnit: a user manager from boot for the daemon's user unit.
    users.users = lib.mapAttrs (_name: ucfg: {
      linger = lib.mkIf (ucfg.bootFetch && ucfg.daemonUserUnit) (lib.mkDefault true);
    }) cfg.users;

    # Home layer via the shared platform-neutral fragment. Sources are
    # strings → out-of-store symlinks into the host's osfiles checkout
    # (live-edit). Foreign/HM-standalone hosts import the same fragment
    # directly (e.g. hosts/cos-ucc/home.nix) with store-path sources.
    home-manager.users = lib.mapAttrs (name: ucfg: {
      imports = [ ./ucc.nix ];
      systemd.user.services.ccc-statusd = lib.mkIf (daemonInUserUnit name ucfg) (daemonUserUnit name);
      systemd.user.services.ucc-update = lib.mkIf (daemonInUserUnit name ucfg) (
        installerUserUnit name ucfg
      );
      osf.ucc = {
        enable = true;
        systemPromptSource = ucfg.systemPromptSource;
        claudeMdSource = ucfg.claudeMdSource;
        codex.enable = ucfg.codex.enable;
        # codex.package: ucc.nix defaults it to the flake-pinned codex build.
        # claudeSettings: stays null here — the NixOS path owns the settings
        # deploy via agent-claude-settings-<user> (no double-apply).
      };
    }) cfg.users;
  };
}
