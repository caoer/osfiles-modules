_: {
  programs.eza = {
    enable = true;
    icons = "auto";
    git = true;
  };

  programs.zsh.shellAliases = {
    ls = "eza --icons=auto --group-directories-first";
    l = "eza -l --git --icons=auto --group-directories-first";
  };
}
