{ config, lib, pkgs, ... }:
let
  cfg = config.osf.yazi;
in
{
  options.osf.yazi = {
    enable = lib.mkEnableOption "yazi file manager";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.yazi
      pkgs.duckdb
      pkgs.tailspin
      pkgs.mdcat
    ];

    programs.zsh.initContent = lib.mkAfter ''
      function yy() {
        local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
        yazi "$@" --cwd-file="$tmp"
        if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
          builtin cd -- "$cwd"
        fi
        rm -f -- "$tmp"
      }
      alias rr=yy
    '';

    xdg.configFile."yazi".source = ./config;
  };
}
