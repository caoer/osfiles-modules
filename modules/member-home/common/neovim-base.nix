# Portable neovim base. Config/plugins/LSPs come from symlinked ~/.config/nvim (LazyVim/Mason).
{ pkgs, lib, ... }:
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    viAlias = true;
    vimdiffAlias = true;
    withRuby = false;
    withPython3 = lib.mkDefault false;

    initLua = ''
      vim.g.mapleader = " "
      vim.g.maplocalleader = "\\"
      require("config.lazy")
    '';

    extraPackages = with pkgs; [
      git
      curl
      wget
      unzip
      gcc
      tree-sitter
      ripgrep
      fd
      statix
      nil
      sops
    ];
  };
}
