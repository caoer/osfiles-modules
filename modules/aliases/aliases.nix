{ config, lib, ... }:
let
  cfg = config.osf.aliases;
in
{
  options.osf.aliases = {
    enable = lib.mkEnableOption "shell aliases";
  };

  config = lib.mkIf cfg.enable {
    programs.zsh.shellAliases = {
      vi = "nvim";

      fj = "fj -H git.0xdao.app";
      tt = "ucc-auto";

      c = "tput clear";

      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      "....." = "cd ../../../..";
      "......" = "cd ../../../../..";
    };
  };
}
