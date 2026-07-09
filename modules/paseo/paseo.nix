# modules/paseo/paseo.nix — shared home-manager fragment for paseo config.
#
# Platform-neutral HM module for managing the paseo daemon's config file.
# Extracted from the former agent/hm.nix paseo-specific options.
#
# Two config paths, mutually exclusive:
#
#   configSource (static): symlink/copy ~/.paseo/config.json from a source.
#     string   → out-of-store symlink (live-edit; target must exist on host)
#     nix path → copied into the store (immutable; rebuild to change)
#
#   paseoConfig (dynamic): same provider-discovery machinery as the NixOS/sm
#     daemon modules (agentLib.mkPaseoConfigGenScript — scans ucc-* wrappers,
#     builds agents.providers, merges onto the nix base config), but run as an
#     HM ACTIVATION step instead of a systemd ExecStartPre. This is the darwin
#     leg: on macOS the daemon is spawned by Paseo.app, so there is no unit
#     hook to anchor regeneration — the config regenerates on every HM switch
#     and the running daemon picks it up on its next restart. The file is
#     written as a plain WRITABLE file (never a store symlink): paseo's
#     onboard / config-save writeFileSync's that path, which would EROFS-crash
#     against a read-only symlink. Declarative content still wins — the next
#     switch re-lays it.
{ config, lib, pkgs, ... }:
let
  cfg = config.osf.paseo;
  agentLib = import ../ucc/lib.nix { inherit pkgs; };
  sourceType = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
  resolve = src: if builtins.isString src then config.lib.file.mkOutOfStoreSymlink src else src;

  home = config.home.homeDirectory;
  genScript = agentLib.mkPaseoConfigGenScript {
    name = config.home.username;
    inherit home;
    uccBinDir = "${home}/.local/share/ucc/bin";
    baseConfigFile = agentLib.mkPaseoBaseConfig {
      name = config.home.username;
      inherit (cfg.paseoConfig) listen relay features browserTools enableTerminalAgentHooks autoArchiveAfterMerge authPasswordHash;
    };
    inherit (cfg.paseoConfig) defaultLauncher providerOverrides profilePresets;
  };
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
        Mutually exclusive with paseoConfig.
      '';
    };

    paseoConfig = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { options = agentLib.paseoConfigOptions lib; });
      default = null;
      description = ''
        Structured paseo config — dynamic provider discovery from ucc-*
        wrappers (~/.local/share/ucc/bin), regenerated on every HM
        activation. The running daemon applies it on its next restart.
        Mutually exclusive with configSource.
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
    (lib.mkIf (cfg.paseoConfig != null) {
      assertions = [
        {
          assertion = cfg.configSource == null;
          message = "osf.paseo: configSource and paseoConfig are mutually exclusive";
        }
      ];
      # rm first: a stale symlink (earlier configSource generation) would make
      # the gen script write THROUGH it into the store — clear, then re-lay.
      home.activation.paseoGenConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run rm -f "${home}/.paseo/config.json"
        run ${genScript}
      '';
    })
  ]);
}
