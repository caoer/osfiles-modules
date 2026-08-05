# modules/yazi/yazi.nix — yazi file manager + shared cyazi-derived config.
#
# yaziPackage is injected by _all-hm.nix from the flake's nixpkgs-yazi pin
# (yazi 26.5.6). The config under ./config targets that schema (group
# fetchers, git plugin @since 26.5.6); shipping pkgs.yazi from a lagging
# consumer nixpkgs breaks rr with `missing field id in prepend_fetchers`
# and `Plugin git requires at least Yazi 26.5.6`.
{ yaziPackage }:
{ config, lib, pkgs, ... }:
let
  cfg = config.osf.yazi;
in
{
  options.osf.yazi = {
    enable = lib.mkEnableOption "yazi file manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = yaziPackage;
      defaultText = lib.literalExpression "nixpkgs-yazi.yazi (26.5.6 pin)";
      description = "Yazi package. Defaults to the fleet pin (26.5.6).";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.package
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
