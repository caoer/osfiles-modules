{ config, lib, ... }:
let
  cfg = config.osf.starship;
in
{
  options.osf.starship = {
    enable = lib.mkEnableOption "starship prompt";
  };

  config = lib.mkIf cfg.enable {
    programs.starship = {
      enable = true;
      enableZshIntegration = true;
      settings = builtins.fromTOML (builtins.readFile ./starship-server.toml);
    };
  };
}
