# modules/member-home — HM profile for semi-managed dev boxes.
#
# Single profile merging server + dev toolchains. Absorbs:
#   common/ (git, aliases, neovim, atuin, yazi, starship, zoxide, session)
#   linux/  (btop, direnv, eza, glow, lazygit, server-files)
#   config/ (nvim, tmux, yazi, starship, atuin, lazygit, glow, direnv, remote-env)
#
# Per-owner content (ssh.nix, paseo config) stays in consumer repos.
# All settings use lib.mkDefault where appropriate — override with mkForce
# or plain assignment in per-owner repos.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./common
    ./linux
  ];

  programs = {
    home-manager.enable = true;

    atuin.enableZshIntegration = lib.mkForce true;
    atuin.settings = builtins.fromTOML (builtins.readFile ./config/atuin/config.toml);

    starship.settings = builtins.fromTOML (
      builtins.readFile ./config/starship/starship-server.toml
    );

    zsh = {
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

    tmux = {
      enable = true;
      extraConfig =
        builtins.readFile ./config/tmux/tmux-base.conf
        + "\n"
        + builtins.readFile ./config/tmux/tmux.remote-mode.conf;
    };

    git.signing.format = null;

    bat = {
      enable = true;
      config = {
        theme = "TwoDark";
        pager = "less -FR";
      };
    };

    fzf.enable = true;
    ripgrep.enable = true;
  };

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

  xdg.configFile = {
    "atuin/config.toml".force = lib.mkForce true;
    "btop/btop.conf".force = lib.mkForce true;
    "direnv/direnv.toml".force = lib.mkForce true;
    "direnv/direnvrc".force = lib.mkForce true;
    "glow/glow.yml".force = lib.mkForce true;
    "glow/tokyo-night.json".force = lib.mkForce true;
  };

  home.packages = with pkgs; [
    (writeScriptBin "pbcopy" (builtins.readFile ./config/remote-env/bin/pbcopy))
    glow
    lazydocker
    nodejs
    go
    uv
    dua
    sesh
    fd
    lnav
    # Dev toolchains (merged from dev.nix — the split adds no value for semi-managed boxes)
    rustc
    cargo
    gh
    bun
  ];
}
