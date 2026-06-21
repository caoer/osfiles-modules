{ config, lib, ... }:
let
  cfg = config.osf.zoxide;
in
{
  options.osf.zoxide = {
    enable = lib.mkEnableOption "zoxide directory jumper";
  };

  config = lib.mkIf cfg.enable {
    programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
      options = [ ];
    };
  };
}
