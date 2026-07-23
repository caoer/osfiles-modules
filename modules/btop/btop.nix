{ config, lib, ... }:
let
  cfg = config.osf.btop;

  # Launch wrapper: btop themes are fixed light OR dark palettes (no truecolor
  # adaptive theme exists), so a dark theme on a light terminal reads as
  # "dark box on light". Pick the theme at launch from the macOS appearance
  # (the same signal wezterm/tmux/theme-picker use) and the active wezterm
  # theme-family, matching btop's bundled light/dark theme for that family
  # where one exists, else a good per-variant default. btop resolves the
  # theme by NAME from its bundled share dir, so no store paths are hardcoded.
  # We inherit the deployed btop.conf and only swap color_theme +
  # theme_background=False (blend with the terminal bg). `defaults` is absent
  # off macOS, so servers fall through to the dark default.
  btopFn = ''
    btop() {
      local variant=dark fam="" theme
      if command -v defaults >/dev/null 2>&1 \
        && [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" != "Dark" ]; then
        variant=light
      fi
      [ -r "$HOME/.config/wezterm/theme-family" ] \
        && fam=$(head -1 "$HOME/.config/wezterm/theme-family" 2>/dev/null)
      if [ "$variant" = light ]; then
        case "$fam" in
          gruvbox)    theme=gruvbox_light ;;
          everforest) theme=everforest-light-medium ;;
          solarized)  theme=solarized_light ;;
          kanagawa)   theme=kanagawa-lotus ;;
          *)          theme=flat-remix-light ;;
        esac
      else
        case "$fam" in
          gruvbox)    theme=gruvbox_dark_v2 ;;
          everforest) theme=everforest-dark-medium ;;
          solarized)  theme=solarized_dark ;;
          kanagawa)   theme=kanagawa-wave ;;
          nord)       theme=nord ;;
          dracula)    theme=dracula ;;
          *)          theme=tokyo-night ;;
        esac
      fi
      local base="$HOME/.config/btop/btop.conf"
      local dir="''${XDG_CACHE_HOME:-$HOME/.cache}/btop"
      local cfg="$dir/active.conf"
      mkdir -p "$dir"
      {
        [ -r "$base" ] && grep -vE '^[[:space:]]*(color_theme|theme_background)[[:space:]]*=' "$base"
        printf 'color_theme = "%s"\ntheme_background = False\n' "$theme"
      } > "$cfg"
      command btop --config "$cfg" "$@"
    }
  '';
in
{
  options.osf.btop = {
    enable = lib.mkEnableOption "btop system monitor";
  };

  config = lib.mkIf cfg.enable {
    programs.btop = {
      enable = true;
      settings = {
        # Sane default for a direct `command btop`; the wrapper overrides per
        # appearance. theme_background=false blends with the terminal bg.
        color_theme = "tokyo-night";
        theme_background = false;
        shown_boxes = "proc cpu";
        update_ms = 3000;
        proc_sorting = "pid";
        proc_reversed = true;
        presets = "cpu:1:default,proc:0:default cpu:0:default,mem:0:default,net:0:default cpu:0:block,net:0:tty";
        save_config_on_exit = false;
      };
    };

    programs.zsh.initContent = lib.mkAfter btopFn;
    programs.bash.initExtra = lib.mkAfter btopFn;

    xdg.configFile."btop/btop.conf".force = lib.mkForce true;
  };
}
