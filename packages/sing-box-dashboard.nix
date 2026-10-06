{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_11,
  nodejs_24,
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
})
