{ config, lib, pkgs, ... }:
let
  cfg = config.osf.glow;
  yamlFormat = pkgs.formats.yaml { };
  glowConfigFile = yamlFormat.generate "glow.yml" {
    style = "auto";
    mouse = false;
    pager = false;
    width = 80;
    all = false;
  };

  # Launch wrapper: glow's `style = "auto"` detects the terminal background via
  # an OSC query, which tmux swallows — so inside tmux it defaults to the dark
  # style and renders dark on a light appearance. Pick the style explicitly at
  # launch: the osf-theme oracle resolves the variant on every platform
  # (darwin: appearance via `defaults`; linux: OSF_APPEARANCE/cache seeded by
  # the shell hook's OSC query). Curated tokyo-night.json for dark, builtin
  # `light` style for light. Without osf-theme (osf.theme disabled) keep the
  # old darwin-only `defaults` check; bare servers then fall through to dark.
  glowFn = ''
    glow() {
      local style="$HOME/.config/glow/tokyo-night.json" variant=dark
      if command -v osf-theme >/dev/null 2>&1; then
        variant="$(osf-theme 2>/dev/null || echo dark)"
      elif command -v defaults >/dev/null 2>&1 \
        && [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" != "Dark" ]; then
        variant=light
      fi
      [ "$variant" = light ] && style=light
      command glow -s "$style" "$@"
    }
  '';
in
{
  options.osf.glow = {
    enable = lib.mkEnableOption "glow markdown viewer";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.glow ];

    programs.zsh.initContent = lib.mkAfter glowFn;
    programs.bash.initExtra = lib.mkAfter glowFn;

    xdg.configFile = {
      "glow/glow.yml" = {
        source = glowConfigFile;
        force = lib.mkForce true;
      };
      "glow/tokyo-night.json" = {
        source = ./tokyo-night.json;
        force = lib.mkForce true;
      };
    };
  };
}
