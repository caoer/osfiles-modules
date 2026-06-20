# Portable git settings. user.name/email set in per-owner users.nix.
_: {
  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      init.defaultBranch = "main";
      core.editor = "nvim";
      pull.rebase = false;
      rerere.enabled = true;
      push.default = "current";
      push.autoSetupRemote = true;
    };
  };
}
