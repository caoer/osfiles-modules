{ config, lib, ... }:
let
  cfg = config.osf.git;
in
{
  options.osf.git = {
    enable = lib.mkEnableOption "git config";
  };

  config = lib.mkIf cfg.enable {
    programs.git = {
      enable = true;
      lfs.enable = true;
      signing.format = null;
      settings = {
        init.defaultBranch = "main";
        core.editor = "nvim";
        pull.rebase = false;
        rerere.enabled = true;
        push.default = "current";
        push.autoSetupRemote = true;
      };
    };

    programs.zsh.shellAliases = {
      g = "git";
      ga = "git add";
      gb = "git branch";
      gc = "git commit --verbose";
      gca = "git commit --verbose --all";
      gcam = "git commit --all --message";
      gcamc = "gcam '[WIP] - 🚧'";
      gcl = "git clone --recurse-submodules";
      gco = "git checkout";
      gfo = "git fetch origin";
      gl = "git log --stat";
      gp = "git push";
      gpl = "git pull";
      gst = "git status";
      gsta = "git stash push";
      gws = "git status";
      hb = "gh browse";
    };
  };
}
