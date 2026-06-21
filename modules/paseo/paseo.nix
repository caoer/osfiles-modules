# modules/paseo/paseo.nix — shared home-manager fragment for paseo config.
#
# Platform-neutral HM module for managing the paseo daemon's config file.
# Extracted from the former agent/hm.nix paseo-specific options.
#
# Source type semantics (configSource):
#   string   → out-of-store symlink (live-edit; target must exist on host)
#   nix path → copied into the store (immutable; rebuild to change)
{ config, lib, ... }:
let
  cfg = config.osf.paseo;
  sourceType = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
  resolve = src: if builtins.isString src then config.lib.file.mkOutOfStoreSymlink src else src;
in
{
  options.osf.paseo = {
    enable = lib.mkEnableOption "paseo daemon";

    configSource = lib.mkOption {
      type = sourceType;
      default = null;
      description = ''
        Paseo daemon config → ~/.paseo/config.json. String = out-of-store
        symlink (live-edit), path = store copy. null = unmanaged.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf (cfg.configSource != null) {
      home.file.".paseo/config.json" = {
        source = resolve cfg.configSource;
        force = true;
      };
    })
  ]);
}
