{ config, lib, ... }:
let
  cfg = config.osf.atuin;
in
{
  options.osf.atuin = {
    enable = lib.mkEnableOption "atuin shell history";
  };

  config = lib.mkIf cfg.enable {
    programs.atuin = {
      enable = true;
      enableZshIntegration = lib.mkForce true;
      settings = builtins.fromTOML (builtins.readFile ./config.toml);
    };

    xdg.configFile."atuin/config.toml".force = lib.mkForce true;
  };
}
