# packages/paseo.nix — fleet paseo wrapper: keep node-pty's native addon.
#
# Upstream 0.3.0 through 0.4.0 `scripts/trace-daemon.mjs` only copies
#   node_modules/node-pty/prebuilds/${platform}-${arch}/**
# but `@getpaseo/server` depends on node-pty@1.2.0-beta.15, which:
#   - often ships *no* prebuilds in the official tarball (0.3.0-beta.2 had them)
#   - is resolved under packages/server/node_modules/node-pty
#   - is rebuilt by the Nix package to build/Release/pty.node, which the
#     tracer also misses
# The terminal worker then dies on:
#   Cannot find module './prebuilds/linux-x64/pty.node'
#   → "Terminal worker is not running"
#
# This wrapper copies whatever pty.node `npm rebuild node-pty` produced into
# every node-pty tree the daemon can resolve, and fails the build if none
# exists. Apply once at the flake pin (packages.paseo + module defaults).
{
  lib,
  stdenv,
  paseo,
  # fetchNpmDeps hash is nixpkgs-revision-sensitive. Upstream's
  # nix/npm-deps.hash is for paseo's own nixpkgs pin; consumers that
  # `follows` a different nixpkgs (osfiles, member nodes) must override.
  # Bump when `nix build` reports a new `got:` hash.
  npmDepsHash ? "sha256-dUvEe+j2E1ptWtjCAi858TnmugqT/+GrgfYJA74oB5I=",
}:
let
  pinned = paseo.override { inherit npmDepsHash; };
  plat =
    if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64 then
      "linux-x64"
    else if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64 then
      "linux-arm64"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64 then
      "darwin-arm64"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isx86_64 then
      "darwin-x64"
    else
      throw "paseo: unsupported platform ${stdenv.hostPlatform.system} for node-pty";
in
pinned.overrideAttrs (old: {
  postInstall = ''
    ${old.postInstall or ""}
    set -eu
    shopt -s globstar nullglob
    src=""
    for f in \
      packages/server/node_modules/node-pty/prebuilds/${plat}/pty.node \
      packages/server/node_modules/node-pty/build/Release/pty.node \
      node_modules/node-pty/prebuilds/${plat}/pty.node \
      node_modules/node-pty/build/Release/pty.node; do
      if [ -f "$f" ]; then src="$f"; break; fi
    done
    if [ -z "$src" ]; then
      src="$(find . -name pty.node -not -path './.*' | head -n 1 || true)"
    fi
    if [ -z "''${src:-}" ] || [ ! -f "$src" ]; then
      echo "paseo: node-pty pty.node missing after rebuild (platform=${plat})" >&2
      find . -path '*node-pty*' \( -name package.json -o -name '*.node' \) >&2 || true
      exit 1
    fi

    # If the tracer only kept the hoisted copy, also place one where the
    # worker resolves (packages/server/node_modules/node-pty).
    nested="$out/lib/paseo/packages/server/node_modules/node-pty"
    if [ ! -d "$nested" ]; then
      for cand in $out/lib/paseo/node_modules/node-pty; do
        if [ -d "$cand" ]; then
          mkdir -p "$(dirname "$nested")"
          cp -a "$cand" "$nested"
          break
        fi
      done
    fi

    injected=0
    for dest in $out/lib/paseo/**/node-pty; do
      [ -d "$dest" ] || continue
      mkdir -p "$dest/prebuilds/${plat}" "$dest/build/Release"
      cp -a "$src" "$dest/prebuilds/${plat}/pty.node"
      cp -a "$src" "$dest/build/Release/pty.node"
      injected=1
    done
    if [ "$injected" -eq 0 ]; then
      echo "paseo: no node-pty directory in $out; tracer omitted the package" >&2
      find "$out/lib/paseo" -iname '*pty*' >&2 || true
      exit 1
    fi
    echo "paseo: injected $src into $injected node-pty tree(s) (${plat})"
  '';
})
