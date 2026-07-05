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
          # Agent fleets spawn dozens of panes at once; concurrent .envrc
          # loads contend and cross direnv's default 5s warning threshold
          # even though each load is sub-second in isolation.
          warn_timeout = "30s";
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
