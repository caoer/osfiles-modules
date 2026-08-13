# osf-theme — the single light/dark variant oracle for themed CLI tools.
#
# Problem: tools that must KNOW the variant to pick a fixed theme (btop theme
# files, bat syntax themes, glow styles, vim background) each guessed on their
# own. On macOS the appearance is queryable (`defaults`), so per-tool wrappers
# worked; servers have no appearance oracle, so every tool degraded to a
# pinned dark theme or a flaky per-tool OSC query (tmux swallows some).
#
# Fix: ONE resolver (osf-theme.sh, see its verb table), one cached state
# (~/.local/state/osf-theme/variant), every consumer reads it:
#   - shell hook (below) exports OSF_APPEARANCE + BAT_THEME once per session;
#     new sessions (env unset) query the terminal via OSC 11 and sync
#     consumers — every SSH connection is a sync point, the linux twin of the
#     mac's wezterm appearance hook. Nested/tmux shells inherit the env free.
#   - btop: osf.btop's color_theme=active file is repointed by `apply`.
#   - glow: the osf.glow wrapper asks `osf-theme` instead of `defaults`.
# Tools that ride ANSI palette roles (yazi, lazygit, starship, eza, fzf) need
# none of this — the terminal palette already follows the appearance.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.theme;

  osfTheme = pkgs.writeShellScriptBin "osf-theme" (builtins.readFile ./osf-theme.sh);

  shellHook = ''
    # osf-theme: resolve the light/dark variant once per session. New sessions
    # ($OSF_APPEARANCE unset) query the terminal and sync consumers; nested
    # shells and tmux panes inherit the env and skip the query.
    if command -v osf-theme >/dev/null 2>&1; then
      if [ -z "''${OSF_APPEARANCE:-}" ]; then
        export OSF_APPEARANCE="$(osf-theme login 2>/dev/null || echo dark)"
      fi
      case "$OSF_APPEARANCE" in
      light) export BAT_THEME="${cfg.batLight}" ;;
      *) export BAT_THEME="${cfg.batDark}" ;;
      esac

      # Follow the variant STATE FILE across prompts: herdr/tmux panes live
      # for days, and a mid-session appearance flip reaches them as a file
      # update (mac flip push, plain-login re-query, `osf-theme sync`). An
      # mtime probe per prompt is ~zero cost; env re-exports only on change,
      # so tools launched from old panes (vi, bat, btop) pick up the current
      # variant without a new shell.
      _osf_theme_refresh() {
        local f="''${XDG_STATE_HOME:-$HOME/.local/state}/osf-theme/variant" m v
        [ -r "$f" ] || return 0
        m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 0
        [ "$m" = "''${_OSF_THEME_MTIME:-}" ] && return 0
        _OSF_THEME_MTIME="$m"
        v=$(cat "$f" 2>/dev/null)
        case "$v" in
        dark | light) ;;
        *) return 0 ;;
        esac
        export OSF_APPEARANCE="$v"
        case "$v" in
        light) export BAT_THEME="${cfg.batLight}" ;;
        *) export BAT_THEME="${cfg.batDark}" ;;
        esac
      }
      if [ -n "''${ZSH_VERSION:-}" ]; then
        typeset -ga precmd_functions
        case " ''${precmd_functions[*]:-} " in
        *" _osf_theme_refresh "*) ;;
        *) precmd_functions+=(_osf_theme_refresh) ;;
        esac
      elif [ -n "''${BASH_VERSION:-}" ]; then
        case ";''${PROMPT_COMMAND:-};" in
        *"_osf_theme_refresh"*) ;;
        *) PROMPT_COMMAND="_osf_theme_refresh''${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
        esac
      fi
    fi
  '';
in
{
  options.osf.theme = {
    enable = lib.mkEnableOption "osf-theme light/dark variant resolver";
    batDark = lib.mkOption {
      type = lib.types.str;
      default = "TwoDark";
      description = "BAT_THEME exported for the dark variant (must match the bat config's theme-dark).";
    };
    batLight = lib.mkOption {
      type = lib.types.str;
      default = "OneHalfLight";
      description = "BAT_THEME exported for the light variant (must match the bat config's theme-light).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ osfTheme ];
    programs.zsh.initContent = lib.mkAfter shellHook;
    programs.bash.initExtra = lib.mkAfter shellHook;
  };
}
