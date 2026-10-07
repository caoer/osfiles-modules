{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_11,
  nodejs_24,
  writeShellScript,
  coreutils,
  findutils,
  src,
}:

# sing-box's own web dashboard, built from our fork
# (git.0xdao.app/caoer115/sing-box-dashboard, flake input
# `sing-box-dashboard-src`): upstream SagerNet/sing-box-dashboard plus a
# Groups tab per outbound that creates groups at run time (oix's region
# groups), read from our sing-box's Group.owner. Served by the sing-box `api`
# service at /dashboard/ from dashboard.path; a directory without sing-box's
# .etag file is served as-is, so this store path never self-updates.
# Bump: `nix flake update sing-box-dashboard-src`, then refresh pnpmDeps.hash.
let
  # The fork's vendor/iterm2-color-schemes submodule commit, only the
  # directory the build turns into terminal themes.
  colorSchemes = fetchFromGitHub {
    owner = "mbadolato";
    repo = "iTerm2-Color-Schemes";
    rev = "8c84dd1a859f36ec8601b082bd97b4ec888f0f4d";
    sparseCheckout = [ "windowsterminal" ];
    hash = "sha256-OQj5Qn+yqw+4z4YwtbSMOHt3oKdDTb78cadeQzNcni4=";
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "sing-box-dashboard";
  version = "0-unstable-${src.shortRev or "dirty"}";
  inherit src;

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-MCld/J2LBtAz2bS00ICjCQN/QPXlLDKwzEGtFwlEl8c=";
  };

  nativeBuildInputs = [
    nodejs_24
    pnpm_11
    pnpmConfigHook
  ];

  buildPhase = ''
    runHook preBuild
    pnpm exec buf generate
    node scripts/gen-icons.mjs
    node scripts/gen-terminal-themes.mjs ${colorSchemes}/windowsterminal
    pnpm build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';

  passthru = {
    # For .woodpecker.yml, which pushes every fixed-output input to
    # cache.0xtau.com; passthru leaves the derivation unchanged.
    inherit colorSchemes;

    # `stage <dir>` rebuilds <dir> as the directory to give sing-box's
    # dashboard.path; run it before sing-box starts (ExecStartPre). sing-box
    # serves the files with Go's http.FileServer, whose Last-Modified is the
    # file mtime: from the store that is 1970-01-01T00:00:01 for every build,
    # so a browser keeps index.html heuristically fresh for years and every
    # revalidation answers 304 — a deployed build never reaches it. The staged
    # copy gives index.html, sw.js and the other unhashed files mtime 0, which
    # the file server treats as unknown: no Last-Modified, If-Modified-Since
    # ignored, so they are fetched whole on every load. assets/ (content-
    # hashed names) stays a store symlink and keeps its long cache life.
    stage = writeShellScript "sing-box-dashboard-stage" ''
      set -eu
      PATH=${lib.makeBinPath [ coreutils findutils ]}
      src=${finalAttrs.finalPackage}
      dest=''${1:?usage: sing-box-dashboard-stage <dir>}
      rm -rf "$dest.new"
      mkdir -p "$dest.new"
      for entry in "$src"/*; do
        if [ "''${entry##*/}" = assets ]; then
          ln -s "$entry" "$dest.new/assets"
        else
          cp -R "$entry" "$dest.new/"
        fi
      done
      chmod -R u+w "$dest.new"
      find "$dest.new" -mindepth 1 -path "$dest.new/assets" -prune -o -exec touch -h -d @0 {} +
      rm -rf "$dest"
      mv "$dest.new" "$dest"
    '';
  };
})
