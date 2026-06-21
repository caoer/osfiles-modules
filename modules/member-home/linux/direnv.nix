{ configDir }:
_: {
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
    stdlib = builtins.readFile (configDir + "/direnv/lib/sops.sh");
  };
}
