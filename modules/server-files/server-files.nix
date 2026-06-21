{ lib, ... }:
{
  options.osf.server-files = {
    enable = lib.mkEnableOption "linux server dotfiles";
  };
  # Config deployments have been distributed to individual tool modules.
  # This module preserved for the option namespace.
}
