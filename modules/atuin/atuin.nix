{ config, lib, ... }:
let
  cfg = config.osf.atuin;
in
{
  options.osf.atuin = {
    enable = lib.mkEnableOption "atuin shell history";
  };

  config = lib.mkIf cfg.enable {
    programs.atuin = {
      enable = true;
      enableZshIntegration = lib.mkForce true;
      settings = {
        search_mode = "fuzzy";
        filter_mode = "global";
        filter_mode_shell_up_key_binding = "directory";
        inline_height_shell_up_key_binding = 10;
        workspaces = true;
        invert = false;
        ctrl_n_shortcuts = false;
        enter_accept = true;
        history_filter = [ "--session-id [a-f0-9-]{36}" ];

        stats = {
          common_subcommands = [
            "apt"
            "cargo"
            "colmena"
            "composer"
            "dnf"
            "docker"
            "dotnet"
            "git"
            "go"
            "home-manager"
            "ip"
            "jj"
            "just"
            "kubectl"
            "nix"
            "nixos-rebuild"
            "nmcli"
            "npm"
            "osf"
            "pecl"
            "pnpm"
            "podman"
            "port"
            "systemctl"
            "tmux"
            "yarn"
          ];
          common_prefix = [ "sudo" ];
          ignored_commands = [
            "cd"
            "ls"
            "ll"
            "clear"
            "pwd"
            "exit"
          ];
        };

        sync.records = true;

        logs.dir = "~/.config/zt/.cache/atuin/logs";

        daemon = {
          enabled = false;
          autostart = false;
        };
      };
    };

    xdg.configFile."atuin/config.toml".force = lib.mkForce true;
  };
}
