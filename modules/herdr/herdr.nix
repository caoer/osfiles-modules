# modules/herdr/herdr.nix — herdr (agent terminal multiplexer) for every host.
#
# One config for the whole fleet. `assets/config.toml` is ZT's live herdr
# config, promoted here so osfiles (mac) and the semi-managed consumers
# (coscene-nix-foreign, member nodes) read the SAME file instead of forking a
# copy per repo. Same pattern as cyazi: the config has its own home, the mac
# symlinks that checkout out-of-store, Linux hosts get the store copy.
#
# Two delivery shapes, because the mac and the boxes want opposite things:
#   manageConfig = true  (default, Linux) — read-only store symlink. In-app
#                        settings writes (prefix+s) cannot persist; edit the
#                        repo file and rebuild.
#   manageConfig = false (mac) — this module installs the BINARIES only;
#                        osfiles' home/darwin/files.nix points ~/.config/herdr
#                        at its own checkout so prefix+s writes land in git.
#
# Files are placed INDIVIDUALLY, never as a directory: ~/.config/herdr also
# holds live state (sockets, session.json, plugins.json, plugin checkouts),
# which a directory symlink would make read-only and break.
#
# Plugins are deliberately NOT nix-managed — herdr builds them on the host and
# owns plugins.json. `herdr-plugins-sync` (scripts/, pins in that file)
# installs the pinned set; it is idempotent and leaves local dev links alone.
# Plugin *settings* DO ride here, as assets/plugins/<id>/.
{ herdrPackages }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.herdr;

  # The helper commands assets/config.toml binds by bare name from its
  # [[keys.command]] entries. Runtime deps stay unwrapped on purpose:
  # herdr-todo wants the host's nvim, herdr-plugins-sync the host's herdr,
  # both resolved from the PATH herdr hands to custom commands.
  herdrScripts = pkgs.runCommand "herdr-scripts" { } ''
    mkdir -p $out/bin
    install -m 555 ${./scripts/herdr-poke-scheme} $out/bin/herdr-poke-scheme
    install -m 555 ${./scripts/herdr-todo} $out/bin/herdr-todo
    install -m 555 ${./scripts/herdr-plugins-sync} $out/bin/herdr-plugins-sync
  '';
in
{
  options.osf.herdr = {
    enable = lib.mkEnableOption "herdr terminal multiplexer + fleet config";

    package = lib.mkOption {
      type = lib.types.package;
      default = herdrPackages.herdr;
      defaultText = lib.literalExpression "herdr flake package (central pin)";
      description = "herdr package. Defaults to this flake's central pin.";
    };

    manageConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Place config.toml and plugin settings at all. Set false on hosts that
        own those paths themselves (the mac, via osfiles home/darwin/files.nix).
      '';
    };

    configSource = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/opt/nix-foreign/config/herdr";
      description = ''
        Directory holding config.toml and plugins/<id>/… on the host. A STRING
        path becomes an out-of-store symlink, so edits to those files apply
        live — `herdr server reload-config` and they are in effect, no rebuild
        and no 3-repo flake-bump chain. Same trick as codexConfigSource.

        Null (default) takes the read-only store copy shipped in assets/:
        reproducible, but in-app settings writes cannot persist.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.package
      # Same profile bucket as herdr itself — that is what puts the helpers on
      # the PATH herdr passes through to custom commands.
      herdrScripts
    ];

    xdg.configFile =
      let
        # Nix path -> immutable store copy. String path -> out-of-store
        # symlink, edits live. Same source list either way, so a host can flip
        # between reproducible and hackable without the file set drifting.
        src =
          rel:
          if cfg.configSource == null then
            ./assets + "/${rel}"
          else
            config.lib.file.mkOutOfStoreSymlink "${cfg.configSource}/${rel}";
      in
      lib.mkIf cfg.manageConfig {
        "herdr/config.toml".source = src "config.toml";

        "herdr/plugins/config/jhochenbaum.hunkdiff/config.toml".source =
          src "plugins/jhochenbaum.hunkdiff/config.toml";
        "herdr/plugins/config/official.browser/browser.json".source =
          src "plugins/official.browser/browser.json";
      };
  };
}
# NOT placed here: $UCC_HOME/config/ccc-herdr.star (the painter's render(v)
# row vocabulary). assets/ccc-herdr.star is kept as the versioned copy of a
# file that previously existed on exactly one machine, but nix is the wrong
# owner: a fresh host also needs a RUNNING `ccc-herdr painter run`, which
# nothing starts, so placing the file alone still leaves the agent view dead.
# The plugin owns both halves — painter lifecycle and a sane default when the
# star is absent (today: silent fallback, internal/painter/config.go:80).
# Tracked with ccc-herdr (reported to session c642cf8c).

