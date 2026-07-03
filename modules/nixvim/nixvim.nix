# modules/nixvim/nixvim.nix — NixVim via cnixvim (caoer/cnixvim).
#
# cnixvim is a thin wrapper flake over upstream khaneliman/khanelivim
# (direct flake input — not the caoer/nixvim fork, which is staged as
# reference in staging-repos) that builds neovim with zt customization
# modules layered on top. We just consume the package.
#
# cnixvimPackages is injected by _all-hm.nix from the flake input.
{ cnixvimPackages }:
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

    variant = lib.mkOption {
      type = lib.types.enum [
        "default"
        "server"
      ];
      default = "default";
      description = ''
        cnixvim package variant. "default" is the workstation build
        (khanelivim standard profile, ~13 GB closure); "server" is the
        small-host build (basic profile + zt trims, ~1.3 GB closure).
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = cnixvimPackages.${cfg.variant};
      defaultText = lib.literalExpression "cnixvim.packages.\${system}.\${variant}";
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
