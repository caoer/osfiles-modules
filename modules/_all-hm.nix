# modules/_all-hm.nix — single HM import for consumers.
# Enables nothing by default — consumers toggle osf.<tool>.enable.
{ cnixvimFlake, nixpkgsYazi }:
{ config, lib, pkgs, ... }:
{
  imports = [
    ./aliases/aliases.nix
    ./clipboard/clipboard.nix
    ./atuin/atuin.nix
    ./btop/btop.nix
    ./direnv/direnv.nix
    ./eza/eza.nix
    ./git/git.nix
    ./glow/glow.nix
    ./lazygit/lazygit.nix
    (import ./nixvim/nixvim.nix {
      cnixvimPackages = cnixvimFlake.packages.${pkgs.system};
    })
    ./osf-theme/osf-theme.nix
    ./starship/starship.nix
    ./tmux/tmux.nix
    (import ./yazi/yazi.nix {
      # Resolve yazi from the pinned nixpkgs-yazi input (26.5.6), not the
      # consumer's pkgs.yazi which often lags at 26.1.22.
      yaziPackage =
        (import nixpkgsYazi {
          inherit (pkgs.stdenv.hostPlatform) system;
          config = { };
          overlays = [ ];
        }).yazi;
    })
    ./zoxide/zoxide.nix
    ./zsh/zsh.nix
    ./ucc/ucc.nix
    ./paseo/paseo.nix
  ];

  # Deferred from member-home/default.nix — cross-cutting concerns.
  config = {
    programs.home-manager.enable = true;

    home.activation.migrateFromStoreCopy = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      configHome="${config.xdg.configHome}"
      for d in atuin btop direnv glow eza lazygit; do
        if [ -L "$configHome/$d" ]; then
          $DRY_RUN_CMD rm -f "$configHome/$d"
          $DRY_RUN_CMD mkdir -p "$configHome/$d"
        fi
      done
      dataHome="${config.xdg.dataHome}"
      if [ -d "$dataHome" ] && [ "$(stat -c %U "$dataHome")" = "root" ]; then
        $DRY_RUN_CMD chown ${config.home.username} "$dataHome"
      fi
    '';
  };
}
