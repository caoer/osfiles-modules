{ config, lib, pkgs, ... }:
let
  cfg = config.osf.nvim;
in
{
  options.osf.nvim = {
    enable = lib.mkEnableOption "neovim";
  };

  config = lib.mkIf cfg.enable {
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

    xdg.configFile = {
      "nvim/lua".source = ./lua;
      "nvim/stylua.toml".source = ./stylua.toml;
      "nvim/spell".source = ./spell;
    };

    # Seed mutable copies of LazyVim state files. Only writes if missing.
    home.activation.seedNvimMutableState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      target_dir="${config.xdg.configHome}/nvim"
      $DRY_RUN_CMD mkdir -p "$target_dir"
      for f in lazyvim.json lazy-lock.json; do
        target="$target_dir/$f"
        src="${builtins.path { path = ./.; name = "nvim-module"; }}/$f"
        if [ ! -e "$target" ] && [ -e "$src" ]; then
          $DRY_RUN_CMD install -m 0644 "$src" "$target"
        fi
      done
    '';
  };
}
