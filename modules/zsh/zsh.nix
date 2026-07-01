{ config, lib, pkgs, ... }:
let
  cfg = config.osf.zsh;
in
{
  options.osf.zsh = {
    enable = lib.mkEnableOption "zsh session config";
  };

  config = lib.mkIf cfg.enable {
    home.sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
      PAGER = "less";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    programs.zsh = {
      enable = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      history.size = 50000;
      shellAliases = {
        ll = "eza -l --git --icons=auto --group-directories-first";
        la = "eza -la --git --icons=auto --group-directories-first";
        lt = "eza --tree --level=2 --icons=auto";
        cat = "bat --style=plain";
      };
      initContent = lib.mkAfter ''
        if type __zoxide_zi_widget &>/dev/null; then
          bindkey '^g' __zoxide_zi_widget
        fi
      '';
    };

    programs.bat = {
      enable = true;
      config = {
        theme = "TwoDark";
        pager = "less -FR";
      };
    };

    programs.fzf.enable = true;
    programs.ripgrep.enable = true;

    home.packages = with pkgs; [
      lazydocker
      nodejs
      go
      uv
      dua
      sesh
      fd
      lnav
      rustc
      cargo
      gh
      bun
    ];
  };
}
