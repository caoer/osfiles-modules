# modules/_all-hm.nix — single HM import for consumers.
# Enables nothing by default — consumers toggle osf.<tool>.enable.
{ cnixvimFlake }:
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
      cnixvimPackage = cnixvimFlake.packages.${pkgs.system}.default;
    })
    ./starship/starship.nix
    ./tmux/tmux.nix
    ./yazi/yazi.nix
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
