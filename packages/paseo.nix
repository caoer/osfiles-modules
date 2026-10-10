# packages/paseo.nix — the fleet's paseo, taken from upstream's Linux release.
#
# getpaseo/paseo publishes `Paseo-<v>-x64.tar.gz` on every GitHub release: the
# Electron desktop bundle, whose resources/app.asar carries the complete daemon
# and CLI (@getpaseo/server, @getpaseo/cli and their node_modules) and whose
# app.asar.unpacked carries the native addons (node-pty, sherpa-onnx,
# msgpackr-extract). All three addons are N-API, so nixpkgs' node runs the
# bundle headless — no Electron, no display, no npm install, no npmDepsHash.
#
# Build: extract the asar (paseo-asar-extract.cjs), patchelf the addons against
# libstdc++, wrap node with the same two entry points the source build had:
#   bin/paseo-server  supervisor-entrypoint.js (systemd ExecStart)
#   bin/paseo         the CLI
# The desktop's web UI (resources/app-dist) is placed where the server looks
# for its bundled web UI (dist/server/web-ui); it is served only when
# features.webUi is enabled.
#
# Upstream ships Linux x64 only, so this package is x86_64-linux only.
#
# Bump: set `version`, then `nix store prefetch-file <url>` for `hash`.
# The tarball is a fixed-output path, identical under every nixpkgs, and CI
# (.woodpecker.yml) pins it and the built package in cache.0xtau.com, so no
# host downloads from GitHub.
{
  lib,
  stdenv,
  fetchurl,
  nodejs_22,
  asar,
  makeWrapper,
  autoPatchelfHook,
}:
let
  nodejs = nodejs_22;
in
stdenv.mkDerivation rec {
  pname = "paseo";
  version = "0.11.2";

  src = fetchurl {
    url = "https://github.com/getpaseo/paseo/releases/download/v${version}/Paseo-${version}-x64.tar.gz";
    hash = "sha256-hOU09+GIM48dd/UoDIoTLMX//Isi/vsWHx1OaXAWT98=";
  };

  nativeBuildInputs = [
    nodejs
    makeWrapper
    autoPatchelfHook
  ];
  buildInputs = [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    lib=$out/lib/paseo
    NODE_PATH=${asar}/lib/node_modules node ${./paseo-asar-extract.cjs} resources/app.asar $lib

    # Linux x64 only: drop other platforms' prebuilds and dirs left empty by
    # entries upstream strips from the release.
    find $lib -path '*/prebuilds/*' -prune -type d ! -name linux-x64 -exec rm -rf {} +
    find $lib -name '*.musl.node' -delete
    find $lib -depth -type d -empty -delete

    # Upstream's pid lock carries the kernel boot id (pid-lock.js bootId), so a
    # clock step after a VM resume does not read the running daemon as dead.

    mkdir -p $lib/node_modules/@getpaseo/server/dist/server
    cp -r resources/app-dist $lib/node_modules/@getpaseo/server/dist/server/web-ui

    for pty in $lib/node_modules/node-pty/prebuilds/linux-x64/pty.node; do
      [ -f "$pty" ] || { echo "paseo: node-pty linux-x64 pty.node missing from the release" >&2; exit 1; }
    done

    mkdir -p $out/bin
    # PASEO_NODE_ENV is paseo's runtime mode; NODE_ENV belongs to spawned agents.
    makeWrapper ${nodejs}/bin/node $out/bin/paseo-server \
      --add-flags "$lib/node_modules/@getpaseo/server/dist/scripts/supervisor-entrypoint.js" \
      --set PASEO_NODE_ENV production
    makeWrapper ${nodejs}/bin/node $out/bin/paseo \
      --add-flags "$lib/node_modules/@getpaseo/cli/dist/index.js" \
      --set PASEO_NODE_ENV production

    runHook postInstall
  '';

  meta = {
    description = "Self-hosted daemon for Claude Code, Codex, and OpenCode (upstream Linux release)";
    homepage = "https://github.com/getpaseo/paseo";
    license = lib.licenses.agpl3Plus;
    mainProgram = "paseo";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
