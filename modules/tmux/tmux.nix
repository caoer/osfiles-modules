{ config, lib, ... }:
let
  cfg = config.osf.tmux;
in
{
  options.osf.tmux = {
    enable = lib.mkEnableOption "tmux";
  };

  config = lib.mkIf cfg.enable {
    programs.tmux = {
      enable = true;
      extraConfig =
        builtins.readFile ./tmux-base.conf
        + "\n"
        + builtins.readFile ./tmux.remote-mode.conf;
    };

    xdg.configFile = {
      "tmux/yank.sh" = { source = ./yank.sh; executable = true; };
      "tmux/pane-dim.sh" = { source = ./pane-dim.sh; executable = true; };
      "tmux/pane-preview.sh" = { source = ./pane-preview.sh; executable = true; };
      "tmux/locus-launcher.sh" = { source = ./locus-launcher.sh; executable = true; };
    };
  };
}
