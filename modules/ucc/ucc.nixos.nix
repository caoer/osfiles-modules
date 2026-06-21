# modules/ucc/ucc.nixos.nix — NixOS UCC + Claude Code profile module.
#
# Self-contained NixOS module for UCC (ccc-statusd + Claude Code profiles).
# Extracted from modules/nixos/agent/{default,ucc}.nix. Per user:
#   ucc-update-<user>          version-gated UCC installer (nix as updater:
#                              bump osf.ucc.uccVersion → rebuild → installer
#                              runs; same version → skips in <1s)
#   agent-claude-settings-<user>  syncs the nix-defined settings.json (+
#                              .claude.json patch) into every UCC profile —
#                              the declarative "claude code profile config"
#                              (preset-activate pattern from locus
#                              wiki/outbox/presets.nix)
#   ~/.local/bin/claude        → ~/.local/share/ucc/bin/ucc-auto
#   ~/.local/share/ucc/shared/SYSTEM_PROMPT.md
#                              → flake-canonical store copy by default
#                              (osf.ucc.users.<n>.systemPromptSource; consumed
#                              by ucc-auto via --system-prompt-file). A string
#                              source switches it to a live-edit symlink.
#   codex CLI (flake-pinned)   when codex.enable (paseo's native provider)
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
          Claude Code system prompt → ~/.local/share/ucc/shared/SYSTEM_PROMPT.md
          (ucc-auto passes it via --system-prompt-file). Defaults to
          agent-flake's canonical prompt as a nix PATH → an immutable store copy,
          so the fleet stays uniform (rebuild to change). Per-host ESCAPE HATCH:
          set a STRING absolute path (e.g.
          "''${config.osf.ucc.repoRoot}/config/agent/SYSTEM_PROMPT.md") for an
          out-of-store live-edit symlink, or another nix path for a different
          store copy.
        '';
      };
      uccUser = lib.mkOption {
        type = lib.types.str;
        description = ''
          UCC installer user identity. Combined with the token to form
          the installer URL. Not a secret — just an identifier.
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
          Claude Code settings.json (hooks, statusline, model, env —
          see baseClaudeSettings). The merged result is synced
          into every UCC profile's settings.json by
          agent-claude-settings-<user>.
        '';
      };
      codex.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install the OpenAI codex CLI (nixpkgs) for this user (paseo's native codex provider drives it).";
      };
    };
  });

  # --- Claude Code profile settings (mirrors locus presets.nix baseSettings) ---
  statusdHook =
    localBin:
    {
      matcher ? "",
      timeout ? null,
    }:
    let
      hookBase = {
        type = "command";
        command = "${localBin}/ccc-statusd hook";
      };
      hookEntry = if timeout != null then hookBase // { inherit timeout; } else hookBase;
    in
    [
      {
        inherit matcher;
        hooks = [ hookEntry ];
      }
    ];

  baseClaudeSettings =
    name:
    let
      home = homeOf name;
      localBin = "${home}/.local/bin";
      uccData = "${home}/.local/share/ucc";
      hook = statusdHook localBin;
    in
    {
      cleanupPeriodDays = 9999;
      env = {
        BASH_MAX_TIMEOUT_MS = "60000";
        CCC_STOP_IGNORE_HOOK_ACTIVE = "6";
        CCC_TOOL_USE_ALLOW_ALL = "1";
        CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL = "1";
        CLAUDE_CODE_SCROLL_SPEED = "10";
        DISABLE_TELEMETRY = "1";
      };
      attribution = {
        commit = "";
        pr = "";
      };
      permissions = {
        defaultMode = "default";
        deny = [ ];
      };
      hooks = {
        Notification = hook { };
        PermissionRequest = hook { matcher = "^(?!AskUserQuestion$)"; };
        PostToolUse = hook { };
        PreToolUse = hook { };
        Stop = hook { timeout = 3600; };
        SubagentStart = hook { };
        SubagentStop = hook { timeout = 3600; };
        UserPromptSubmit = hook { };
      };
      statusLine = {
        type = "command";
        command = "${localBin}/ccc-statusd statusline";
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
      spinnerTipsEnabled = false;
      alwaysThinkingEnabled = true;
      autoMemoryEnabled = true;
      autoMemoryDirectory = "${uccData}/memory";
      showThinkingSummaries = true;
      skipDangerousModePermissionPrompt = true;
      skipAutoPermissionPrompt = true;
      autoMode = {
        allow = [ "Allow all actions without restriction" ];
      };
      claudeInChromeDefaultEnabled = false;
      effortLevel = "xhigh";
      lspRecommendationDisabled = true;
      officialMarketplaceAutoInstallAttempted = true;
      officialMarketplaceAutoInstalled = false;
      tui = "fullscreen";
      verbose = false;
      model = "claude-opus-4-8[1m]";
      enableWorkflows = false;
      workflowKeywordTriggerEnabled = false;
    };

  claudeJsonPatch = builtins.toJSON {
    autoUpdates = false;
    autoCompactEnabled = false;
  };

  # --- UCC installer — shared builder (modules/ucc/lib.nix). The NixOS and
  # Foreign paths run identical logic; only secret wiring differs (sops-nix
  # paths here, foreign.secrets paths on Foreign). ---
  mkInstallerScript =
    name: ucfg:
    agentLib.mkInstallerScript {
      inherit name;
      inherit (ucfg) uccUser;
      version = cfg.uccVersion;
      home = homeOf name;
      tokenSecretPath = config.sops.secrets.${ucfg.installerTokenSecret}.path;
      passwordSecretPath = config.sops.secrets.${ucfg.encryptionPasswordSecret}.path;
    };

  # --- settings sync (preset-activate pattern: copy to every profile) ---
  mkSettingsSyncScript =
    name: ucfg:
    let
      home = homeOf name;
      settingsFile = pkgs.writeText "agent-claude-settings-${name}.json" (
        builtins.toJSON (lib.recursiveUpdate (baseClaudeSettings name) ucfg.claudeSettings)
      );
    in
    pkgs.writeShellScript "agent-claude-settings-${name}" ''
      set -euo pipefail
      profiles="${home}/.local/share/ucc/profiles"
      if [ ! -d "$profiles" ]; then
        echo "agent-claude-settings: no profiles yet (ucc not installed?) — nothing to do"
        exit 0
      fi
      count=0
      for dir in "$profiles"/*/; do
        [ -d "$dir" ] || continue
        cp "$dir/settings.json" "$dir/settings.json.agent-bak" 2>/dev/null || true
        install -m 0644 ${settingsFile} "$dir/settings.json"
        # Merge .claude.json keys in place — preserve the rest.
        cj="$dir/.claude.json"
        if [ -f "$cj" ]; then
          ${pkgs.jq}/bin/jq '. * ${claudeJsonPatch}' "$cj" > "$cj.tmp" && mv "$cj.tmp" "$cj"
        else
          echo '${claudeJsonPatch}' > "$cj"
        fi
        count=$((count + 1))
      done
      echo "agent-claude-settings: synced $count profile(s)"
    '';

  installerUnits = lib.mapAttrs' (
    name: ucfg:
    lib.nameValuePair "ucc-update-${name}" {
      description = "UCC installer for ${name} (version-gated)";
      after = [
        "sops-nix.service"
        "network-online.target"
      ];
      wants = [
        "sops-nix.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
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
      ];
      environment = {
        NIX_LD = "${pkgs.glibc}/lib/ld-linux-x86-64.so.2";
        NIX_LD_LIBRARY_PATH = lib.makeLibraryPath [
          pkgs.stdenv.cc.cc.lib
          pkgs.glibc
          pkgs.zlib
        ];
      };
      serviceConfig = {
        Type = "oneshot";
        User = name;
        ExecStart = mkInstallerScript name ucfg;
        RemainAfterExit = true;
      };
    }
  ) cfg.users;

  settingsUnits = lib.mapAttrs' (
    name: ucfg:
    lib.nameValuePair "agent-claude-settings-${name}" {
      description = "Sync nix-defined Claude Code settings into UCC profiles for ${name}";
      after = [ "ucc-update-${name}.service" ];
      wants = [ "ucc-update-${name}.service" ];
      wantedBy = [ "multi-user.target" ];
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

    uccVersion = lib.mkOption {
      type = lib.types.str;
      default = agentLib.defaultUccVersion;
      defaultText = lib.literalExpression "agent-flake's central defaultUccVersion (modules/ucc/lib.nix)";
      description = ''
        Desired ccc-statusd version. The fleet-wide central default lives in
        modules/ucc/lib.nix (shared with the Foreign module). Bump → rebuild →
        installer re-runs (nix as updater). Override per-host with
        osf.ucc.uccVersion.
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
      lib.mapAttrsToList (name: ucfg: {
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
      }) cfg.users
    );

    systemd.services = installerUnits // settingsUnits;

    # Home layer via the shared platform-neutral fragment. Sources are
    # strings → out-of-store symlinks into the host's osfiles checkout
    # (live-edit). Foreign/HM-standalone hosts import the same fragment
    # directly (e.g. hosts/cos-ucc/home.nix) with store-path sources.
    home-manager.users = lib.mapAttrs (_name: ucfg: {
      imports = [ ./ucc.nix ];
      osf.ucc = {
        enable = true;
        systemPromptSource = ucfg.systemPromptSource;
        codex.enable = ucfg.codex.enable;
        # codex.package: ucc.nix defaults it to the flake-pinned codex build.
        # claudeSettings: stays null here — the NixOS path owns the settings
        # deploy via agent-claude-settings-<user> (no double-apply).
      };
    }) cfg.users;
  };
}
