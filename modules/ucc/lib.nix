# modules/ucc/lib.nix — shared builders for the agent profile, used by BOTH
# the NixOS module (modules/ucc) and the Foreign system-manager module
# (modules/paseo). ONE source of truth for the UCC installer (always the
# latest get-ucc.sui.pics release) and the paseo config render; the platform
# modules differ only in how they wire secrets, PATH, systemd options, and
# the per-platform agentPath tail around these.
{ pkgs }:
let
  installerBaseUrl = "https://get-ucc.sui.pics/installer";

  # Model presets — catalogs of known third-party providers that expose
  # Anthropic-compatible APIs. Presets carry the model list + display metadata;
  # credentials and API endpoints live in the ucc-* wrapper (managed by the
  # UCC installer, not by Nix).
  modelPresets = {
    glm = {
      label = "ZAI (GLM)";
      disallowedTools = [ "WebSearch" ];
      models = [
        { id = "glm-5-turbo"; label = "GLM 5 Turbo"; }
        { id = "glm-5v-turbo"; label = "GLM 5V Turbo"; }
        { id = "glm-5.1[1m]"; label = "GLM 5.1 (1M)"; }
        { id = "glm-5.2[1m]"; label = "GLM 5.2 (1M)"; isDefault = true; }
      ];
    };
    qwen = {
      label = "Qwen (Alibaba)";
      disallowedTools = [ "WebSearch" ];
      models = [
        { id = "qwen3.5-plus"; label = "Qwen 3.5 Plus"; isDefault = true; }
        { id = "qwen3-coder-next"; label = "Qwen 3 Coder Next"; }
      ];
    };
    # MiniMax (https://api.minimax.io) — Anthropic-compatible coding plan.
    # WebSearch is Anthropic server-side only; MiniMax agents get web_search via
    # the minimax-coding-plan-mcp injected by the UCC launcher (MINIMAX_API_KEY /
    # MINIMAX_API_HOST on the profile). Auto-matches minimax-us / minimax-vol / …
    # by the minimax- prefix (longest-key segment rules still prefer zenmux when
    # both match, e.g. minimax/minimax-m3 inside the zenmux catalog is just a
    # model id, not a provider name).
    minimax = {
      label = "MiniMax";
      disallowedTools = [ "WebSearch" ];
      models = [
        { id = "MiniMax-M3[1m]"; label = "MiniMax M3 (1M)"; isDefault = true; }
        { id = "minimax-m3"; label = "MiniMax M3"; }
      ];
    };
    # ZenMux (https://zenmux.ai) — multi-provider router with an
    # Anthropic-compatible endpoint; model ids are vendor-prefixed
    # (anthropic/claude-opus-4.8, not claude-opus-4.8). Catalog: the 1M-context
    # subset of scripts/fetch-zenmux-models.sh output — every entry carries the
    # [1m] suffix so the statusline resolves a 1M window instead of the 200k
    # floor; the launcher strips it before the id reaches the router. Sub-1M
    # models are deliberately absent rather than listed without the suffix.
    # No isDefault on purpose: this one catalog serves every *-zenmux-* profile,
    # and each wrapper already pins its own family via ANTHROPIC_MODEL — a shared
    # default would override the pinned model on launch (grok-zenmux-* launching
    # opus).
    zenmux = {
      label = "ZenMux";
      disallowedTools = [ "WebSearch" ];
      models = [
        { id = "openai/gpt-5.6-luna[1m]"; label = "OpenAI: GPT-5.6 Luna (1M)"; }
        { id = "openai/gpt-5.6-sol[1m]"; label = "OpenAI: GPT-5.6 Sol (1M)"; }
        { id = "openai/gpt-5.6-terra[1m]"; label = "OpenAI: GPT-5.6 Terra (1M)"; }
        { id = "google/gemini-3.5-flash[1m]"; label = "Google: Gemini 3.5 Flash (1M)"; }
        { id = "google/gemini-3.1-pro-preview[1m]"; label = "Google: Gemini 3.1 Pro Preview (1M)"; }
        { id = "google/gemini-3.1-flash-lite[1m]"; label = "Google: Gemini 3.1 Flash Lite (1M)"; }
        { id = "xiaomi/mimo-v2.5-pro[1m]"; label = "Xiaomi: MiMo-V2.5-Pro (1M)"; }
        { id = "qwen/qwen3.7-max[1m]"; label = "Qwen: Qwen3.7-Max (1M)"; }
        { id = "qwen/qwen3.7-plus[1m]"; label = "Qwen: Qwen3.7-Plus (1M)"; }
        { id = "anthropic/claude-opus-4.8[1m]"; label = "Anthropic: Claude Opus 4.8 (1M)"; }
        { id = "anthropic/claude-sonnet-5[1m]"; label = "Anthropic: Claude Sonnet 5 (1M)"; }
        { id = "anthropic/claude-fable-5[1m]"; label = "Anthropic: Claude Fable 5 (1M)"; }
        { id = "deepseek/deepseek-v4-pro[1m]"; label = "DeepSeek: DeepSeek V4 Pro (1M)"; }
        { id = "deepseek/deepseek-v4-flash[1m]"; label = "DeepSeek: DeepSeek V4 Flash (1M)"; }
        { id = "meituan/longcat-2.0[1m]"; label = "Meituan: LongCat-2.0 (1M)"; }
        { id = "minimax/minimax-m3[1m]"; label = "MiniMax: MiniMax M3 (1M)"; }
        { id = "z-ai/glm-5.2[1m]"; label = "Z.AI: GLM 5.2 (1M)"; }
        { id = "x-ai/grok-4.5[1m]"; label = "xAI: Grok 4.5 (1M)"; }
      ];
    };
  };
in
{
  inherit modelPresets;

  # UCC installer always pulls the latest release served by get-ucc.sui.pics
  # (the worker bakes DAEMON_VERSION into the rendered installer). No nix pin
  # — a new tag is live as soon as CI publishes it. The installer itself
  # skips daemon/node/bundle/native when they already match that release.
  # CLI tools (curl, bash, coreutils, gnugrep, …) come from the caller's
  # systemd unit PATH — NixOS via `path`, Foreign via Environment PATH.
  # Secrets are read from on-host paths the caller wires (sops-nix on NixOS,
  # foreign.secrets on Foreign), so this builder is platform-neutral.
  installerBaseUrl = "https://get-ucc.sui.pics/installer";

  mkInstallerScript =
    {
      name,
      home,
      uccUser,
      tokenSecretPath,
      passwordSecretPath,
    }:
    let
      localBin = "${home}/.local/bin";
      uccShare = "${home}/.local/share/ucc/shared";
    in
    pkgs.writeShellScript "ucc-update-${name}" ''
      set -euo pipefail

      UCC_TOKEN=$(cat ${tokenSecretPath})
      UCC_INSTALLER_URL="${installerBaseUrl}?user=${uccUser}&token=$UCC_TOKEN"
      ENCRYPTION_PASSWORD=$(cat ${passwordSecretPath})

      CURRENT=""
      if [ -x "${localBin}/ccc-statusd" ]; then
        CURRENT=$("${localBin}/ccc-statusd" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
      fi
      echo "ucc: installing latest (currently ''${CURRENT:-none})"

      export ENCRYPTION_PASSWORD

      # Disk-backed temp: /tmp is tmpfs on several hosts and routinely full
      # (cos-stex-ucc 2026-07-27: 32G tmpfs at 100% → curl (23) on the
      # ~300MB claude-code bundle). The installer's mktemp calls all respect
      # TMPDIR.
      export TMPDIR="''${TMPDIR:-/var/tmp}"

      # Do not touch ~/.zshrc here. The UCC installer (ccc-statusd worker
      # template) skips nix-managed / read-only shell RCs with a warning;
      # desymlinking broke home-manager (backup clobber on next deploy).

      # Download then execute — avoids curl|bash where pipe exit codes get lost.
      TMPSCRIPT=$(mktemp "$TMPDIR/ucc-install.XXXXXX")
      trap 'rm -f "$TMPSCRIPT"' EXIT
      curl -fsSL "$UCC_INSTALLER_URL" -o "$TMPSCRIPT"
      bash "$TMPSCRIPT"

      if [ ! -x "${localBin}/ccc-statusd" ]; then
        echo "ucc: FATAL: ccc-statusd not found after install" >&2
        exit 1
      fi
      INSTALLED=$("${localBin}/ccc-statusd" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)

      # Verify node runs (catches nix-ld / dynamic linking failures).
      if ! "${uccShare}/node/bin/node" --version >/dev/null 2>&1; then
        echo "ucc: FATAL: node binary at ${uccShare}/node/bin/node cannot execute (dynamic linking?)" >&2
        exit 1
      fi

      echo "ucc: v''${INSTALLED:-unknown} installed successfully"
    '';

  # paseo config.json rendered into the store from a consumer-supplied JSON with
  # the @UCC_BIN@ placeholder replaced by the user's ucc bin dir. Both platforms
  # then materialize a WRITABLE copy at ~/.paseo/config.json via a systemd
  # ExecStartPre install (paseo's onboard / config-save writeFileSync's that
  # path; a read-only store symlink would EROFS-crash it).
  #
  # LEGACY: used by consumers that still pass a static paseoConfigFile. New
  # consumers should use mkPaseoConfigGenScript (dynamic provider discovery).
  renderPaseoConfig =
    {
      name,
      uccBinDir,
      configFile,
    }:
    pkgs.writeText "paseo-config-${name}.json" (
      builtins.replaceStrings [ "@UCC_BIN@" ] [ uccBinDir ] (builtins.readFile configFile)
    );

  # --- Dynamic paseo config generation (provider discovery) ---
  #
  # Generates a script that discovers installed ucc-* wrappers at daemon start,
  # builds the agents.providers block (model presets auto-matched by profile
  # name prefix — glm* → glm catalog), merges with a nix-generated base config,
  # and writes ~/.paseo/config.json. Eliminates duplication between R2/DO profile
  # data and the static paseo JSON — the UCC installer (which syncs from the
  # worker DO) is the single source of truth for available profiles.
  #
  # Ordering: paseo-<user>.service must After/Requires ucc-update-<user>.service
  # so wrappers are guaranteed fresh when this script runs.
  mkPaseoConfigGenScript =
    {
      name,
      home,
      uccBinDir,
      baseConfigFile,
      defaultLauncher ? null, # null = "ucc-auto"; string = profile name e.g. "opus48"
      providerOverrides ? { }, # deep-merged into discovered providers
      profilePresets ? { }, # profile name → preset name (from modelPresets)
    }:
    let
      launcher = if defaultLauncher == null then "ucc-auto" else "ucc-${defaultLauncher}";
      launcherName = if defaultLauncher == null then "auto" else defaultLauncher;
      overridesJson = builtins.toJSON providerOverrides;
      resolvedPresets = builtins.mapAttrs (_: presetName: modelPresets.${presetName}) profilePresets;
      resolvedPresetsJson = builtins.toJSON resolvedPresets;
      paseoHome = "${home}/.paseo";
    in
    pkgs.writeShellScript "paseo-gen-config-${name}" ''
      set -euo pipefail

      UCC_BIN="${uccBinDir}"
      CONFIG="${paseoHome}/config.json"
      BASE="${baseConfigFile}"

      mkdir -p "${paseoHome}"

      # --- Build providers from discovered ucc-* wrappers ---
      PROVIDERS='{}'

      # Default claude provider
      PROVIDERS=$(echo "$PROVIDERS" | ${pkgs.jq}/bin/jq --arg cmd "$UCC_BIN/${launcher}" \
        '. + { "claude": { "enabled": true, "command": [$cmd], "env": { "TERM": "xterm-256color" } } }')

      # Discover additional wrappers → extends claude
      # Only include actual profile launchers (comment line: "Launch Claude Code with … profile").
      # Skips utilities: ucc-*-cli, ucc-*-ip, ucc-source-*, ucc-sdk, ucc-cli, ucc-codexd.
      if [ -d "$UCC_BIN" ]; then
        for wrapper in "$UCC_BIN"/ucc-*; do
          [ -x "$wrapper" ] || continue
          wname="''${wrapper##*/ucc-}"
          # paseo requires provider IDs matching /^[a-z][a-z0-9-]*$/. Lowercase
          # + underscores->hyphens, then SKIP anything still invalid. A single
          # bad id (e.g. a stray path-derived profile "Users" -> "Users") makes
          # paseo reject the ENTIRE config.json, bricking the daemon — drop the
          # offender instead of letting it poison every other provider.
          wname=$(echo "$wname" | ${pkgs.coreutils}/bin/tr 'A-Z_' 'a-z-')
          if ! echo "$wname" | ${pkgs.gnugrep}/bin/grep -qE '^[a-z][a-z0-9-]*$'; then
            echo "paseo-gen-config: skipping invalid provider id '$wname' (from $wrapper)" >&2
            continue
          fi

          # Skip built-ins and the default launcher itself
          case "$wname" in
            auto|random|codex|${launcherName}) continue ;;
          esac

          # Only profile launchers — verified by the header comment the installer writes
          if ! ${pkgs.gnused}/bin/sed -n '2p' "$wrapper" | ${pkgs.gnugrep}/bin/grep -q "Launch Claude Code with"; then
            continue
          fi

          PROVIDERS=$(echo "$PROVIDERS" | ${pkgs.jq}/bin/jq \
            --arg n "$wname" --arg cmd "$wrapper" \
            '. + { ($n): { "extends": "claude", "label": $n, "command": [$cmd] } }')
        done
      fi

      # Static built-in providers
      PROVIDERS=$(echo "$PROVIDERS" | ${pkgs.jq}/bin/jq '. + {
        "codex": { "enabled": true },
        "copilot": { "enabled": false },
        "opencode": { "enabled": false },
        "pi": { "enabled": false }
      }')

      # Auto-match model presets by profile-name prefix or hyphen segment:
      # profiles are named <model-family>-<provider-suffix> (glm-zai, glm52-zai,
      # glm-vol, …) or <family>-<router>-<user> (glm-zenmux-zt), and preset keys
      # are model families OR routers. A preset key matches when the provider id
      # starts with it or contains it as a hyphen-bounded segment; the LONGEST
      # matching key wins, so glm-zenmux-zt gets the zenmux catalog
      # (vendor-prefixed ids the router expects), not the ZAI glm one. Provider
      # fields win over the preset (command/extends stay), and the preset's
      # label is dropped — five glm-* providers must not all read "ZAI (GLM)".
      # Explicit profilePresets below still overrides (preset-wins, incl. label).
      AUTO_PRESETS='${builtins.toJSON modelPresets}'
      PROVIDERS=$(echo "$PROVIDERS" | ${pkgs.jq}/bin/jq --argjson auto "$AUTO_PRESETS" '
        . as $base | reduce keys[] as $k ($base;
          ($auto | to_entries | map(select(.key as $p
            | ($k | startswith($p)) or ($k | contains("-" + $p + "-")) or ($k | endswith("-" + $p))))
           | sort_by(.key | length) | last) as $m
          | if $m then .[$k] = (($m.value | del(.label)) * .[$k]) else . end
        )')

      # Apply model presets to matching discovered profiles
      PRESETS='${resolvedPresetsJson}'
      if [ "$PRESETS" != "{}" ]; then
        PROVIDERS=$(echo "$PROVIDERS" | ${pkgs.jq}/bin/jq --argjson presets "$PRESETS" '
          . as $base | $presets | to_entries | reduce .[] as $e ($base;
            if .[$e.key] then .[$e.key] = (.[$e.key] * $e.value)
            else . end
          )')
      fi

      # Apply per-provider overrides (deep merge)
      OVERRIDES='${overridesJson}'
      if [ "$OVERRIDES" != "{}" ] && [ "$OVERRIDES" != "null" ]; then
        PROVIDERS=$(echo "$PROVIDERS" | ${pkgs.jq}/bin/jq --argjson ov "$OVERRIDES" '
          . as $base | $ov | to_entries | reduce .[] as $e ($base;
            if .[$e.key] then .[$e.key] = (.[$e.key] * $e.value)
            else .[$e.key] = $e.value end
          )')
      fi

      # Merge base config + providers → final config.json
      ${pkgs.jq}/bin/jq --argjson providers "$PROVIDERS" \
        '.agents.providers = $providers' "$BASE" > "$CONFIG"

      chmod 0600 "$CONFIG"
      echo "paseo-gen-config: $(echo "$PROVIDERS" | ${pkgs.jq}/bin/jq 'length') provider(s)"
    '';

  # Generate the static base config JSON (everything except agents.providers).
  # Providers are filled at runtime by mkPaseoConfigGenScript.
  mkPaseoBaseConfig =
    {
      name,
      listen ? "127.0.0.1:6767",
      relay ? { endpoint = "paseo-relay.innopals.com:443"; useTls = true; },
      features ? { dictation = { enabled = false; }; voiceMode = { enabled = false; }; },
      browserTools ? { enabled = false; },
      enableTerminalAgentHooks ? false,
      autoArchiveAfterMerge ? false,
      authPasswordHash ? null,
    }:
    pkgs.writeText "paseo-base-${name}.json" (builtins.toJSON {
      version = 1;
      daemon = {
        inherit listen;
        inherit relay;
        inherit browserTools enableTerminalAgentHooks;
        mcp = { injectIntoAgents = true; };
        inherit autoArchiveAfterMerge;
        appendSystemPrompt = "";
        cors = { allowedOrigins = [ "https://app.paseo.sh" ]; };
      } // pkgs.lib.optionalAttrs (authPasswordHash != null) {
        auth = { password = authPasswordHash; };
      };
      app = { baseUrl = "https://app.paseo.sh"; };
      agents = { providers = { }; };
      inherit features;
    });

  # Shared paseoConfig submodule options — ONE schema for all three platform
  # modules (paseo.nixos.nix, paseo.sm.nix, paseo.nix HM). Fields map 1:1 onto
  # mkPaseoBaseConfig (daemon block) + mkPaseoConfigGenScript (providers).
  paseoConfigOptions = lib: {
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
    autoArchiveAfterMerge = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "daemon.autoArchiveAfterMerge (auto-archive worktree agents once their PR merges).";
    };
    authPasswordHash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        daemon.auth.password — bcrypt hash ($2a/$2b/$2y, cost 12) of the
        daemon password. Required when listen is non-loopback. Generate:
        htpasswd -nbBC 12 "" '<password>' | cut -d: -f2. null = no auth.
      '';
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
    browserTools = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { enabled = false; };
      description = "daemon.browserTools (agent browser automation).";
    };
    enableTerminalAgentHooks = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "daemon.enableTerminalAgentHooks (hooks for terminal-launched agents).";
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
    profilePresets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { zai = "glm"; qwen = "qwen"; };
      description = ''
        Maps discovered profile names to model presets (agentLib.modelPresets).
        When ucc-<name> is discovered and <name> has a preset, the preset's
        model catalog (models, label, disallowedTools) is merged in.
      '';
    };
  };
}
