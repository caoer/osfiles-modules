# modules/cvim/cvim.nix — nvim via cvim (caoer/cvim), the fleet's nvim distro.
#
# cvim is a nixvim distro built from ZT's own modules. osfiles ships it to
# every server tier from server-tools standard up, and the mac installs the
# same flake through `nix profile`; this module is the member-host half, so
# one flake builds the editor everywhere.
#
# The package ships bin/nvim and bin/cvim (the same binary under two names) —
# `vv` is the alias for the second, matching the mac shell init.
#
# Variant closures, x86_64-linux, measured at cvim rev 1c552505:
#   server   0.54 GiB   small hosts and root accounts
#   default  4.26 GiB   full workstation surface (go, basedpyright, llvm, mermaid)
#   lab      4.26 GiB   cvim's own scratch build loop
#
# cvimPackages is injected by _all-hm.nix from the flake input.
{ cvimPackages }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.cvim;
in
{
  options.osf.cvim = {
    enable = lib.mkEnableOption "cvim (nvim) as the sole editor";

    variant = lib.mkOption {
      type = lib.types.enum [
        "default"
        "server"
        "lab"
      ];
      default = "default";
      description = ''
        Which cvim package to install. "default" is the workstation build;
        "server" is the budget closure for small hosts.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = cvimPackages.${cfg.variant};
      defaultText = lib.literalExpression "cvim.packages.\${system}.\${variant}";
      description = "The cvim neovim package.";
    };
  };

  config = lib.mkIf cfg.enable {
    # cvim is the sole editor — nothing else in a consumer's tier may ship
    # bin/nvim, or the HM profile buildEnv collides.
    programs.neovim.enable = lib.mkForce false;

    home = {
      packages = [ cfg.package ];

      sessionVariables = {
        EDITOR = lib.mkForce "nvim";
        VISUAL = lib.mkForce "nvim";
      };

      shellAliases = {
        vi = lib.mkForce "nvim";
        vv = "cvim";
      };
    };
  };
}
