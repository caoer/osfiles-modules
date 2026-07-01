{ config, lib, pkgs, ... }:
let
  cfg = config.osf.clipboard;
in
{
  options.osf.clipboard = {
    enable = lib.mkEnableOption "OSC 52 clipboard (pbcopy for remote sessions)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.writeScriptBin "pbcopy" (builtins.readFile ./pbcopy))
    ];

    # zsh: pipe-to-clipboard global alias  (`pwd C` → `pwd | pbcopy`)
    programs.zsh.shellGlobalAliases = lib.mkIf config.programs.zsh.enable {
      C = lib.mkDefault "| pbcopy";
    };

    # bash: pbcopy is already in PATH — no extra config needed

    # fish: abbreviation for piping to clipboard
    programs.fish.shellAbbrs = lib.mkIf config.programs.fish.enable {
      C = "| pbcopy";
    };
  };
}
