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
    stdlib = builtins.readFile ../config/direnv/lib/sops.sh;
  };
}
