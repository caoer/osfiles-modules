# Drop tool configs into ~/.config/ on headless servers via HM store-copy.
{ config, lib, ... }:
let
  configDir = ../config;
in
{
  xdg.configFile = {
    # nvim — read-only LazyVim sources. lazyvim.json and lazy-lock.json
    # are mutated by LazyVim at runtime, seeded as mutable copies below.
    "nvim/lua".source = configDir + "/nvim/lua";
    "nvim/stylua.toml".source = configDir + "/nvim/stylua.toml";
    "nvim/spell".source = configDir + "/nvim/spell";

    "lazygit/config.yml".source = configDir + "/lazygit/config.yml";
    "lazygit/yazi.yml".source = configDir + "/lazygit/yazi.yml";

    "yazi".source = configDir + "/yazi";
    "tmux/yank.sh" = {
      source = configDir + "/tmux/yank.sh";
      executable = true;
    };
    "tmux/pane-dim.sh" = {
      source = configDir + "/tmux/pane-dim.sh";
      executable = true;
    };
    "tmux/pane-preview.sh" = {
      source = configDir + "/tmux/pane-preview.sh";
      executable = true;
    };
    "tmux/locus-launcher.sh" = {
      source = configDir + "/tmux/locus-launcher.sh";
      executable = true;
    };
  };

  # Seed mutable copies of LazyVim state files. Only writes if missing.
  home.activation.seedNvimMutableState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target_dir="${config.xdg.configHome}/nvim"
    $DRY_RUN_CMD mkdir -p "$target_dir"
    for f in lazyvim.json lazy-lock.json; do
      target="$target_dir/$f"
      src="${configDir}/nvim/$f"
      if [ ! -e "$target" ] && [ -e "$src" ]; then
        $DRY_RUN_CMD install -m 0644 "$src" "$target"
      fi
    done
  '';
}
