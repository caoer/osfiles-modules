{ config, lib, pkgs, ... }:
let
  cfg = config.osf.glow;
  yamlFormat = pkgs.formats.yaml { };
  glowConfigFile = yamlFormat.generate "glow.yml" {
    style = "auto";
    mouse = false;
    pager = false;
    width = 80;
    all = false;
  };
in
{
  options.osf.glow = {
    enable = lib.mkEnableOption "glow markdown viewer";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.glow ];

    xdg.configFile = {
      "glow/glow.yml" = {
        source = glowConfigFile;
        force = lib.mkForce true;
      };
      "glow/tokyo-night.json" = {
        source = ./tokyo-night.json;
        force = lib.mkForce true;
      };
    };
  };
}
