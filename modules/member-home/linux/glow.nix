{ configDir }:
{ pkgs, ... }:
let
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
  xdg.configFile = {
    "glow/glow.yml".source = glowConfigFile;
    "glow/tokyo-night.json".source = configDir + "/glow/tokyo-night.json";
  };
}
