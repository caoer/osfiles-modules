{ config, lib, ... }:
let
  cfg = config.osf.btop;
in
{
  options.osf.btop = {
    enable = lib.mkEnableOption "btop system monitor";
  };

  config = lib.mkIf cfg.enable {
    programs.btop = {
      enable = true;
      settings = {
        # btop reads its theme once at launch and its themes are fixed light OR
        # dark files (no truecolor adaptive theme exists), so a dark theme on a
        # light terminal is unreadable. Point at a mutable "active" theme kept
        # current by tmux-theme.sh's sync_btop (fired on every theme change by
        # the same wezterm hook that syncs tmux). This is shell-independent:
        # even a stale tmux pane's btop reads the current theme. theme_background
        # =false blends btop with the terminal background.
        color_theme = "active";
        theme_background = false;
        shown_boxes = "proc cpu";
        update_ms = 3000;
        proc_sorting = "pid";
        proc_reversed = true;
        presets = "cpu:1:default,proc:0:default cpu:0:default,mem:0:default,net:0:default cpu:0:block,net:0:tty";
        save_config_on_exit = false;
      };
    };

    xdg.configFile."btop/btop.conf".force = lib.mkForce true;
  };
}
