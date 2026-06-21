{ config, lib, ... }:
let
  cfg = config.osf.eza;
in
{
  options.osf.eza = {
    enable = lib.mkEnableOption "eza ls replacement";
  };

  config = lib.mkIf cfg.enable {
    programs.eza = {
      enable = true;
      icons = "auto";
      git = true;
    };

    programs.zsh.shellAliases = {
      ls = "eza --icons=auto --group-directories-first";
      l = "eza -l --git --icons=auto --group-directories-first";
    };
  };
}
