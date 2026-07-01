# modules/nixvim/nixvim.nix — NixVim via cnixvim (caoer/cnixvim).
#
# cnixvim is a thin wrapper flake over caoer/nixvim (khanelivim fork)
# that builds neovim with the zt profile. We just consume the package.
#
# cnixvimPackage is injected by _all-hm.nix from the flake input.
{ cnixvimPackage }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.nixvim;
in
{
  options.osf.nixvim = {
    enable = lib.mkEnableOption "NixVim (cnixvim) as the sole editor";

    package = lib.mkOption {
      type = lib.types.package;
      default = cnixvimPackage;
      defaultText = lib.literalExpression "cnixvim.packages.\${system}.default";
      description = "The cnixvim neovim package.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Disable programs.neovim (LazyVim retired) — NixVim is the sole editor.
    programs.neovim.enable = lib.mkForce false;

    home.packages = [ cfg.package ];

    home.sessionVariables.EDITOR = lib.mkForce "nvim";
  };
}
