# modules/ucc/lib.nix — shared builders for the agent profile, used by BOTH
# the NixOS module (modules/ucc) and the Foreign system-manager module
# (modules/paseo). ONE source of truth for the version-gated ucc
# installer and the paseo config render; the platform modules differ only in how
# they wire secrets, PATH, systemd options, and the per-platform agentPath tail
# around these.
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
        { id = "glm-5.1"; label = "GLM 5.1"; }
        { id = "glm-5.2"; label = "GLM 5.2"; isDefault = true; }
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
    # ZenMux (https://zenmux.ai) — multi-provider router with an
    # Anthropic-compatible endpoint; model ids are vendor-prefixed
    # (anthropic/claude-opus-4.8, not claude-opus-4.8). Catalog: the ≥500k-context
    # subset of scripts/fetch-zenmux-models.sh output. No isDefault on purpose:
    # this one catalog serves every *-zenmux-* profile, and each wrapper already
    # pins its own family via ANTHROPIC_MODEL — a shared default would override
    # the pinned model on launch (grok-zenmux-* launching opus).
    zenmux = {
      label = "ZenMux";
      disallowedTools = [ "WebSearch" ];
      models = [
        { id = "x-ai/grok-4.2-fast"; label = "xAI: Grok 4.2 Fast"; }
        { id = "openai/gpt-5.5"; label = "OpenAI: GPT-5.5"; }
        { id = "openai/gpt-5.5-pro"; label = "OpenAI: GPT-5.5 Pro"; }
        { id = "google/gemini-3.5-flash"; label = "Google: Gemini 3.5 Flash"; }
        { id = "google/gemini-3.1-pro-preview"; label = "Google: Gemini 3.1 Pro Preview"; }
        { id = "google/gemini-3.1-flash-lite"; label = "Google: Gemini 3.1 Flash Lite"; }
        { id = "xiaomi/mimo-v2.5-pro"; label = "Xiaomi: MiMo-V2.5-Pro"; }
        { id = "openai/gpt-4.1"; label = "OpenAI: GPT-4.1"; }
        { id = "openai/gpt-4.1-mini"; label = "OpenAI: GPT-4.1 Mini"; }
        { id = "openai/gpt-4.1-nano"; label = "OpenAI: GPT-4.1 Nano"; }
        { id = "qwen/qwen3.7-max"; label = "Qwen: Qwen3.7-Max"; }
        { id = "qwen/qwen3.7-plus"; label = "Qwen: Qwen3.7-Plus"; }
        { id = "qwen/qwen3.6-flash"; label = "Qwen: Qwen3.6 Flash"; }
        { id = "qwen/qwen3-coder-plus"; label = "Qwen: Qwen3-Coder-Plus"; }
        { id = "anthropic/claude-opus-4.8"; label = "Anthropic: Claude Opus 4.8"; }
        { id = "anthropic/claude-sonnet-5"; label = "Anthropic: Claude Sonnet 5"; }
        { id = "anthropic/claude-fable-5"; label = "Anthropic: Claude Fable 5"; }
        { id = "deepseek/deepseek-v4-pro"; label = "DeepSeek: DeepSeek V4 Pro"; }
        { id = "deepseek/deepseek-v4-flash"; label = "DeepSeek: DeepSeek V4 Flash"; }
        { id = "meituan/longcat-2.0"; label = "Meituan: LongCat-2.0"; }
        { id = "minimax/minimax-m3"; label = "MiniMax: MiniMax M3"; }
        { id = "z-ai/glm-5.2"; label = "Z.AI: GLM 5.2"; }
        { id = "x-ai/grok-4.3"; label = "xAI: Grok 4.3"; }
        { id = "x-ai/grok-4.5"; label = "xAI: Grok 4.5"; }
      ];
    };
  };
in
{
  inherit modelPresets;

  # Fleet-wide central default ccc-statusd version. Both module paths (NixOS +
  # Foreign) default osf.{ucc,uccForeign}.uccVersion to this — ONE bump moves the
  # whole fleet. Override per-host via the option.
  defaultUccVersion = "1.11.21";

  # Version-gated UCC installer (nix as updater): compares the installed
  # ccc-statusd version against `version`, runs the Cloudflare installer when it
  # differs (or node is broken), verifies, and is a <1s no-op when already
  # current. CLI tools (curl, bash, coreutils, gnugrep, …) come from the
  # caller's systemd unit PATH — NixOS via `path`, Foreign via Environment PATH.
  # Secrets are read from on-host paths the caller wires (sops-nix on NixOS,
  # foreign.secrets on Foreign), so this builder is platform-neutral.
  # Base URL for the UCC installer — user+token appended per-host.
  installerBaseUrl = "https://get-ucc.sui.pics/installer";

  mkInstallerScript =
    {
      name,
      version,
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
      DESIRED="${version}"

      UCC_TOKEN=$(cat ${tokenSecretPath})
      UCC_INSTALLER_URL="${installerBaseUrl}?user=${uccUser}&token=$UCC_TOKEN"
      ENCRYPTION_PASSWORD=$(cat ${passwordSecretPath})

      CURRENT=""
      if [ -x "${localBin}/ccc-statusd" ]; then
        CURRENT=$("${localBin}/ccc-statusd" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
      fi

      # Full-stack check: ccc-statusd version match AND node binary works.
      if [ "$CURRENT" = "$DESIRED" ] && [ -x "${uccShare}/node/bin/node" ] \
         && "${uccShare}/node/bin/node" --version >/dev/null 2>&1; then
        echo "ucc: v$DESIRED already installed, skipping"
        exit 0
      fi

      echo "ucc: updating $CURRENT → $DESIRED"
      export ENCRYPTION_PASSWORD

      # .zshrc is a read-only HM symlink on NixOS; the installer appends
      # PATH/source lines to it. Replace with a writable copy so the installer
      # doesn't fail at the shell RC step.
      if [ -L "${home}/.zshrc" ]; then
        cp -L "${home}/.zshrc" "${home}/.zshrc.tmp"
        mv "${home}/.zshrc.tmp" "${home}/.zshrc"
      fi
      # cp -L preserves the store file's 444 mode — the copy is read-only even
      # for its owner and the installer's RC append fails. Make writable.
      if [ -f "${home}/.zshrc" ]; then
        chmod u+w "${home}/.zshrc"
      fi

      # Download then execute — avoids curl|bash where pipe exit codes get lost.
      TMPSCRIPT=$(mktemp /tmp/ucc-install.XXXXXX)
      trap 'rm -f "$TMPSCRIPT"' EXIT
      curl -fsSL "$UCC_INSTALLER_URL" -o "$TMPSCRIPT"
      bash "$TMPSCRIPT"

      # Verify ccc-statusd.
      if [ ! -x "${localBin}/ccc-statusd" ]; then
        echo "ucc: FATAL: ccc-statusd not found after install" >&2
        exit 1
      fi
      INSTALLED=$("${localBin}/ccc-statusd" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
      if [ "$INSTALLED" != "$DESIRED" ]; then
        echo "ucc: FATAL: expected v$DESIRED but got v$INSTALLED" >&2
        exit 1
      fi

      # Verify node runs (catches nix-ld / dynamic linking failures).
      if ! "${uccShare}/node/bin/node" --version >/dev/null 2>&1; then
        echo "ucc: FATAL: node binary at ${uccShare}/node/bin/node cannot execute (dynamic linking?)" >&2
        exit 1
      fi

      echo "ucc: v$DESIRED installed successfully"
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
          # Sanitize: paseo requires provider IDs matching /^[a-z][a-z0-9-]*$/
          wname=$(echo "$wname" | ${pkgs.coreutils}/bin/tr '_' '-')

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
      authPasswordHash ? null,
    }:
    pkgs.writeText "paseo-base-${name}.json" (builtins.toJSON {
      version = 1;
      daemon = {
        inherit listen;
        inherit relay;
        inherit browserTools enableTerminalAgentHooks;
        mcp = { injectIntoAgents = true; };
        autoArchiveAfterMerge = false;
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
