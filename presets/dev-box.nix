# presets/dev-box.nix — enables common tool set for semi-managed dev boxes.
# Import AFTER homeManagerModules.default.
{ ... }:
{
  osf.aliases.enable = true;
  osf.atuin.enable = true;
  osf.btop.enable = true;
  osf.direnv.enable = true;
  osf.eza.enable = true;
  osf.git.enable = true;
  osf.glow.enable = true;
  osf.lazygit.enable = true;
  osf.nvim.enable = true;
  osf.starship.enable = true;
  osf.tmux.enable = true;
  osf.yazi.enable = true;
  osf.zoxide.enable = true;
  osf.zsh.enable = true;
  osf.ucc.enable = true;
  osf.paseo.enable = true;
}
