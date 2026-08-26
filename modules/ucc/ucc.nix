# modules/ucc/ucc.nix — shared home-manager fragment for UCC (Claude Code).
#
# Platform-neutral HM module consumed by BOTH:
#   - modules/ucc/ucc.nixos.nix (NixOS hosts: imported per user, sources are
#     strings → out-of-store symlinks into the host's osfiles checkout)
#   - Foreign/HM-standalone hosts (e.g. hosts/cos-ucc/home.nix: sources are
#     nix paths → store copies, for hosts without a checkout)
#
# Owns: ucc PATH wiring + UCC_HOME, claude → ucc launcher link, system
# prompt file, user-scope CLAUDE.md, codex CLI, claude settings deploy. The ucc
# installer and the settings-sync units are platform-specific and live with the
# caller.
#
# Source type semantics (systemPromptSource, claudeMdSource):
#   string   → out-of-store symlink (live-edit; target must exist on host)
#   nix path → copied into the store (immutable; rebuild to change)
#   null     → unmanaged (claudeMdSource defaults here: opt in per host)
#
# force = true on owned files: the ucc installer (claude link) and manual
# setup (system prompt) may have left real files — HM takes them over.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.ucc;
  home = config.home.homeDirectory;

  sourceType = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
  resolve = src: if builtins.isString src then config.lib.file.mkOutOfStoreSymlink src else src;

  # Claude settings.json deploy (osf.ucc.claudeSettings) — the Foreign /
  # HM-standalone analogue of the NixOS path's agent-claude-settings-<user>
  # systemd unit (ucc.nixos.nix) and of locus `just preset`: write one settings.json
  # into every ucc profile + merge a small .claude.json patch. Profiles are
  # created by the ucc installer at runtime, so a glob-loop in an activation
  # step (not home.file) is the only way to reach them; preset-bak mirrors the
  # locus backup. On NixOS hosts this stays null (the systemd unit owns the
  # deploy) — no double-apply.
  settingsFile = pkgs.writeText "claude-settings.json" (builtins.toJSON cfg.claudeSettings);
  claudeJsonPatch = builtins.toJSON {
    autoUpdates = false;
    autoCompactEnabled = false;
  };
  applyClaudeSettings = pkgs.writeShellScript "apply-claude-settings" ''
    set -euo pipefail
    profiles="${home}/.local/share/ucc/profiles"
    [ -d "$profiles" ] || { echo "ucc profiles dir absent — skipping settings deploy"; exit 0; }
    count=0
    for pf in "$profiles"/*/settings.json; do
      [ -f "$pf" ] || continue
      dir=$(dirname "$pf")
      cp "$pf" "$dir/settings.json.preset-bak" 2>/dev/null || true
      cp ${settingsFile} "$pf"
      # Merge keys into .claude.json, preserve the rest (create if missing).
      cj="$dir/.claude.json"
      if [ -f "$cj" ]; then
        ${pkgs.jq}/bin/jq '. * ${claudeJsonPatch}' "$cj" > "$cj.tmp" && mv "$cj.tmp" "$cj"
      else
        echo '${claudeJsonPatch}' > "$cj"
      fi
      count=$((count + 1))
    done
    echo "claude settings: applied to $count profile(s)"
  '';

  # Re-assert herdr's OWN SessionStart reporter after the settings deploy.
  #
  # `ucc-cli herdr setup` installs two things per profile: hooks/herdr-agent-state.sh
  # (the reporter script) and a SessionStart entry in that profile's settings.json.
  # applyClaudeSettings above `cp`s one flat settings.json over every profile, which
  # DELETES that entry — measured on cos-stex-ucc before this step existed: 23/23
  # profiles still had the script, 0/23 still had the hook, so the panes went unlabelled.
  #
  # It cannot be nix-declared into claudeSettings: the hook command embeds each
  # profile's OWN absolute path (bash <home>/.local/share/ucc/profiles/<p>/hooks/
  # herdr-agent-state.sh session) — 23 different values on that host, and the profiles
  # only exist after the ucc installer has run. So re-run the installer's own idempotent
  # command instead of re-implementing it.
  #
  # PATH is load-bearing, not politeness: herdr-setup.mjs finds the binary via four
  # hardcoded candidates (/run/current-system/sw/bin, ~/.local/bin, /opt/homebrew/bin,
  # /usr/local/bin) plus $PATH. On a foreign/HM-standalone host herdr comes from
  # home.packages and lands in profileDirectory, which is on NONE of those — and HM
  # activation inherits the invoking shell's PATH (`nix run … home-manager -- switch`
  # need not carry it). Without this prepend the step silently no-ops on exactly the
  # hosts that need it.
  #
  # --if-installed exits 0 where herdr is absent; this module runs on hosts without it.
  herdrHookSetup = pkgs.writeShellScript "ucc-herdr-hook-setup" ''
    set -euo pipefail
    cli="${home}/.local/share/ucc/bin/ucc-cli"
    [ -x "$cli" ] || { echo "ucc-cli absent — skipping herdr hook setup"; exit 0; }
    export PATH="${config.home.profileDirectory}/bin:$PATH"
    # Never fatal: herdr is optional and a multiplexer hook must not brick a rebuild
    # (herdr-setup.mjs makes the same promise internally). Loud on the way out.
    "$cli" herdr setup --if-installed || echo "herdr hook setup FAILED (non-fatal) — panes will render unlabelled"
  '';
in
{
  options.osf.ucc = {
    enable = lib.mkEnableOption "ucc agent home layer (paths, claude link, prompts, codex)";

    claudeLauncher = lib.mkOption {
      type = lib.types.str;
      default = "ucc-auto";
      description = "ucc launcher (in ~/.local/share/ucc/bin) that ~/.local/bin/claude points at.";
    };

    systemPromptSource = lib.mkOption {
      type = sourceType;
      default = null;
      description = ''
        Claude Code system prompt → ~/.local/share/ucc/shared/SYSTEM_PROMPT.md
        (ucc-auto passes it via --system-prompt-file). String = out-of-store
        symlink (live-edit), path = store copy. null = unmanaged.
      '';
    };

    claudeMdSource = lib.mkOption {
      type = sourceType;
      default = null;
      description = ''
        User-scope CLAUDE.md → ~/.local/share/ucc/shared/CLAUDE.md, the file
        every profile's CLAUDE.md symlinks to. String = out-of-store symlink
        (live-edit), path = store copy. null = unmanaged, which is the default:
        a host opts in explicitly.

        Why this option exists: the ucc installer creates
        profiles/<n>/CLAUDE.md -> ../../shared/CLAUDE.md unconditionally and
        treats a dangling link as valid (scripts/repair.mjs), so it never
        provisions the target. Nothing else did either — the composer writes
        only the host it runs on. A host with no writer therefore serves every
        agent an empty user-scope layer while looking correctly installed.

        Set this ONLY on hosts where nothing else writes that path. A host whose
        composer also writes it would have two writers and the store symlink
        would fight the composer.
      '';
    };

    codex.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the codex CLI (osf.ucc.codex.package) — paseo's native codex provider drives it.";
    };

    codex.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/codex.nix { };
      defaultText = lib.literalExpression "agent-flake's pinned packages/codex.nix (ahead of nixpkgs)";
      description = ''
        codex CLI package. Defaults to agent-flake's pinned build (one fleet
        version, bumped centrally in packages/codex.nix). Override per-host for
        an outlier (e.g. pkgs.codex from nixpkgs).
      '';
    };

    codexConfigSource = lib.mkOption {
      type = sourceType;
      default = null;
      description = ''
        codex config → ~/.codex/config.toml. String = out-of-store symlink
        (live-edit), path = store copy. null = unmanaged. Only config.toml is
        declarative — codex's runtime state (goals/state/memories/logs sqlite,
        installation_id, OAuth) stays mutable per-host, never in the nix store.
      '';
    };

    claudeSettings = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
      description = ''
        Claude Code settings.json content (attrset). When set, an HM activation
        applies it to every ~/.local/share/ucc/profiles/*/settings.json (backing
        the prior file up to settings.json.preset-bak) and merges
        {autoUpdates, autoCompactEnabled} = false into each profile's
        .claude.json. The Foreign / HM-standalone analogue of the NixOS path's
        agent-claude-settings-<user> systemd unit (which owns this deploy on
        NixOS hosts — leave this null there to avoid a double-apply). The ucc
        installer creates profiles at runtime, so this runs on each HM switch
        over whatever profiles exist. null = unmanaged.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home = {
      sessionPath = [
        "${home}/.local/bin"
        "${home}/.local/share/ucc/bin"
        "${home}/.local/share/ucc/bin/skills-bin"
      ];
      sessionVariables.UCC_HOME = "${home}/.local/share/ucc";

      packages = lib.optional cfg.codex.enable cfg.codex.package;

      file = {
        # claude = configured ucc launcher. Dangling until the ucc
        # installer runs; force-restored by rebuild if the installer or a
        # manual `ln -sf` ever repoints it.
        ".local/bin/claude" = {
          source = config.lib.file.mkOutOfStoreSymlink "${home}/.local/share/ucc/bin/${cfg.claudeLauncher}";
          force = true;
        };
      }
      // lib.optionalAttrs (cfg.systemPromptSource != null) {
        ".local/share/ucc/shared/SYSTEM_PROMPT.md" = {
          source = resolve cfg.systemPromptSource;
          force = true;
        };
      }
      // lib.optionalAttrs (cfg.claudeMdSource != null) {
        # The target of every profiles/<n>/CLAUDE.md symlink. force = true
        # because a host may already carry a real file here from a hand-copy.
        ".local/share/ucc/shared/CLAUDE.md" = {
          source = resolve cfg.claudeMdSource;
          force = true;
        };
      }
      // lib.optionalAttrs (cfg.codexConfigSource != null) {
        # config.toml only — siblings (the *.sqlite runtime DBs) are left alone.
        ".codex/config.toml" = {
          source = resolve cfg.codexConfigSource;
          force = true;
        };
      };

      # Settings deploy — runtime ucc profiles can't be reached by home.file, so
      # apply over the glob in an activation step (after the writeBoundary, where
      # mutating the live home is allowed). $DRY_RUN_CMD keeps `build`/dry-run
      # side-effect-free.
      activation = lib.optionalAttrs (cfg.claudeSettings != null) {
        deployClaudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD ${applyClaudeSettings}
        '';
      }
      // {
        # Runs on every osf.ucc host, not just the ones deploying settings: it also
        # covers a fresh box where the installer ran before herdr existed. The dep on
        # deployClaudeSettings is conditional because that entry only exists when
        # claudeSettings != null — naming an absent dag entry is an eval error.
        uccHerdrHook = lib.hm.dag.entryAfter (
          [ "writeBoundary" ] ++ lib.optional (cfg.claudeSettings != null) "deployClaudeSettings"
        ) ''
          $DRY_RUN_CMD ${herdrHookSetup}
        '';
      };
    };
  };
}
