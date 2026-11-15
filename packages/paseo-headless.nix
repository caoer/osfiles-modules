# packages/paseo-headless.nix — paseo taken from upstream's desktop release,
# run headless under nixpkgs' node. flake.nix exports it as
# packages.aarch64-darwin.paseo; the other systems keep packages/paseo.nix
# (built from source).
#
# getpaseo/paseo publishes `Paseo-<v>-x64.tar.gz` (Linux) and
# `Paseo-<v>-arm64.zip` (macOS) on every GitHub release: the Electron desktop
# bundle, whose app.asar carries the complete daemon
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
# Platforms: x86_64-linux (the tarball) and aarch64-darwin (the zip). On macOS
# the headless daemon is the point: run from Paseo.app, every process the daemon
# spawns is attributed to the notarized app, and on macOS 26.7 tccd's
# stapled-ticket registration for it deadlocks syspolicyd so every first exec
# on the host hangs. Under nixpkgs' node the spawns are attributed to node.
# The macOS build also carries the bundle's builtin-plugins (the server's
# usage sources and providers) and restores the execute bits the asar
# extraction drops from app.asar.unpacked (esbuild, node-pty's spawn-helper).
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
  unzip,
}:
let
  nodejs = nodejs_22;
  inherit (stdenv.hostPlatform) isDarwin;
  release =
    {
      x86_64-linux = {
        asset = "x64.tar.gz";
        hash = "sha256-kfTp0DGu+t/tqDyvSv9C6Vj9txASAgZ/Z4LfbyNHZGI=";
        resources = "resources";
        prebuild = "linux-x64";
        note = "Linux x64 only";
      };
      aarch64-darwin = {
        asset = "arm64.zip";
        hash = "sha256-EuxtSOQqhhA9++q7CpoJXjwG+vE2UAVee+FfJFWv8Dw=";
        resources = "Contents/Resources";
        prebuild = "darwin-arm64";
        note = "macOS arm64 only";
      };
    }
    .${stdenv.hostPlatform.system}
      or (throw "paseo: no upstream release for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation rec {
  pname = "paseo";
  version = "0.11.4";

  src = fetchurl {
    url = "https://github.com/getpaseo/paseo/releases/download/v${version}/Paseo-${version}-${release.asset}";
    inherit (release) hash;
  };

  nativeBuildInputs = [
    nodejs
    makeWrapper
  ]
  ++ (if isDarwin then [ unzip ] else [ autoPatchelfHook ]);
  buildInputs = lib.optionals (!isDarwin) [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    lib=$out/lib/paseo
    NODE_PATH=${asar}/lib/node_modules node ${./paseo-asar-extract.cjs} ${release.resources}/app.asar $lib

    # ${release.note}: drop other platforms' prebuilds and dirs left empty by
    # entries upstream strips from the release.
    find $lib -path '*/prebuilds/*' -prune -type d ! -name ${release.prebuild} -exec rm -rf {} +
    find $lib -name '*.musl.node' -delete
    find $lib -depth -type d -empty -delete

    # Upstream's pid lock carries the kernel boot id (pid-lock.js bootId), so a
    # clock step after a VM resume does not read the running daemon as dead.

    mkdir -p $lib/node_modules/@getpaseo/server/dist/server
    cp -r ${release.resources}/app-dist $lib/node_modules/@getpaseo/server/dist/server/web-ui
    ${lib.optionalString isDarwin ''
      cp -r ${release.resources}/builtin-plugins $lib/node_modules/@getpaseo/server/dist/server/builtin-plugins
      (cd ${release.resources}/app.asar.unpacked && find . -type f -perm -u+x) | while IFS= read -r f; do
        [ ! -f "$lib/$f" ] || chmod +x "$lib/$f"
      done
    ''}
    for pty in $lib/node_modules/node-pty/prebuilds/${release.prebuild}/pty.node; do
      [ -f "$pty" ] || { echo "paseo: node-pty ${release.prebuild} pty.node missing from the release" >&2; exit 1; }
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
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
