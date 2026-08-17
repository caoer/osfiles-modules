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

  # Nix path -> immutable store copy. String path -> out-of-store symlink, edits
  # live. Same source list either way, so a host can flip between reproducible
  # and hackable without the file set drifting.
  #
  # Lives at MODULE level, not inside the xdg.configFile binding: home.file
  # below needs it too. 40d4b57 defined it in a let scoped to xdg.configFile and
  # referenced it from home.file — 'error: undefined variable src', which broke
  # osf-modules main outright for every consumer that bumped. Keep it here.
  src =
    rel:
    if cfg.configSource == null then
      ./assets + "/${rel}"
    else
      config.lib.file.mkOutOfStoreSymlink "${cfg.configSource}/${rel}";
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

    xdg.configFile = lib.mkIf cfg.manageConfig {
      "herdr/config.toml".source = src "config.toml";

      "herdr/plugins/config/jhochenbaum.hunkdiff/config.toml".source =
        src "plugins/jhochenbaum.hunkdiff/config.toml";
      "herdr/plugins/config/official.browser/browser.json".source =
        src "plugins/official.browser/browser.json";
    };

    # The ccc-herdr painter's row vocabulary — render(v) for every pane label
    # (the agent view). home.file, NOT xdg.configFile: the painter resolves
    # $UCC_HOME/config/ccc-herdr.star (internal/painter/config.go ConfigPath),
    # which is UCC_HOME-relative and has nothing to do with XDG.
    #
    # A MISSING file is legal — the painter falls back to built-in defaults and
    # the agent view silently renders nothing, which is exactly how it was lost
    # on cos-stex-ucc. Placing it is the whole point.
    #
    # Follows configSource like every other file here: with it set the host gets
    # an out-of-store symlink and keeps live-editability; null gives the store
    # copy. Gated on manageConfig so the mac, which owns its own paths and
    # already carries this file from its ccc-private-config checkout, is not
    # double-placed.
    home.file = lib.mkIf cfg.manageConfig {
      ".local/share/ucc/config/ccc-herdr.star".source = src "ccc-herdr.star";
    };
  };
}
# Still owned by the ccc-herdr plugin, NOT by nix: painter lifecycle. Placing
# ccc-herdr.star (home.file above) fixes the row vocabulary, but a fresh host
# still needs a RUNNING `ccc-herdr painter run` and nothing here starts one, so
# the agent view stays dark until the painter is up. The painter also reads its
# config only at START — after a rebuild that changes the star, restart it
# (`ccc-herdr painter restart`) or the old vocabulary keeps rendering.

