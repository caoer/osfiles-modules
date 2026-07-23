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
  # launch from the macOS appearance (the same signal wezterm/tmux use): the
  # curated tokyo-night.json for dark, the builtin `light` style for light.
  # `defaults` is absent off macOS, so servers fall through to dark.
  glowFn = ''
    glow() {
      local style="$HOME/.config/glow/tokyo-night.json"
      if command -v defaults >/dev/null 2>&1 \
        && [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" != "Dark" ]; then
        style=light
      fi
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
