# common/ — portable home-manager modules for semi-managed dev boxes.
# No per-owner content (ssh.nix stays in per-owner repos).
{
  imports = [
    ./atuin.nix
    ./yazi.nix
    ./lazygit.nix
    ./misc-prompt.nix
    ./git-aliases.nix
    ./git-base.nix
    ./neovim-base.nix
    ./aliases-common.nix
    ./session.nix
  ];
}
