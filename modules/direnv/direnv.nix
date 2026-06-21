{ config, lib, ... }:
let
  cfg = config.osf.direnv;
in
{
  options.osf.direnv = {
    enable = lib.mkEnableOption "direnv";
  };

  config = lib.mkIf cfg.enable {
    programs.direnv = {
      enable = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
      config = {
        global = {
          hide_env_diff = true;
          log_format = "";
        };
      };
      stdlib = builtins.readFile ./sops-stdlib.sh;
    };

    xdg.configFile = {
      "direnv/direnv.toml".force = lib.mkForce true;
      "direnv/direnvrc".force = lib.mkForce true;
    };
  };
}
