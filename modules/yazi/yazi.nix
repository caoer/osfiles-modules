# modules/yazi/yazi.nix — yazi file manager + shared cyazi-derived config.
#
# yaziPackage is injected by _all-hm.nix from the flake's nixpkgs-yazi pin
# (yazi 26.5.6). The config under ./config targets that schema (group
# fetchers, git plugin @since 26.5.6); shipping pkgs.yazi from a lagging
# consumer nixpkgs breaks rr with `missing field id in prepend_fetchers`
# and `Plugin git requires at least Yazi 26.5.6`.
#
# hunkPackage is the `g d` differ (keymap.toml). Injected the same way, and
# nullable: upstream hunk builds aarch64-darwin/aarch64-linux/x86_64-linux
# only, so on x86_64-darwin _all-hm.nix passes null and the binding simply has
# no binary — rather than failing eval for the whole module set.
{
  yaziPackage,
  hunkPackage ? null,
}:
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
    ]
    # The `g d` differ. Ships WITH the keymap that calls it — the previous
    # binding shelled out to `delta`, which no osf module has ever installed,
    # so `g d` was a broken key for every consumer that did not happen to
    # bring its own. Binary and binding land together or not at all.
    ++ lib.optional (hunkPackage != null) hunkPackage;

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
