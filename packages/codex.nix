# Codex — OpenAI Codex CLI. Prebuilt static musl binaries from GitHub releases.
# Pinned ahead of nixpkgs (which lags upstream). Bump: update version + both
# sha256 (nix-prefetch-url each tarball URL).
#
# Two tarballs per release: the CLI and codex-code-mode-host. Codex resolves
# the host beside its own binary and fails closed without it ("Code Mode is
# unavailable … host executable was not found").
#
# The wrapper turns off `daemon_auto_start`. With it on, the TUI hands its
# session to a self-updating app-server daemon that needs a mutable package
# layout (codex-package.json, codex-path/, codex-resources/); a store path has
# none, so a bare `codex` exits "this CLI has no complete local package".
{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
}:

let
  version = "0.159.2";

  assets = {
    "x86_64-linux" = {
      target = "x86_64-unknown-linux-musl";
      sha256 = "1shn2qw15dldy9096w5k443zpw3hsfny33pgn2csfhbd4h6nnn16";
      codeModeHostSha256 = "03v3yz3qmi027vv1rmn6xc6scg9qc40br3i0s4l0gv94gd50qszv";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "codex: unsupported platform ${stdenv.hostPlatform.system}");

  release = "https://github.com/openai/codex/releases/download/rust-v${version}";

  codeModeHost = fetchurl {
    url = "${release}/codex-code-mode-host-${asset.target}.tar.gz";
    sha256 = asset.codeModeHostSha256;
  };

in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    url = "${release}/codex-${asset.target}.tar.gz";
    inherit (asset) sha256;
  };

  sourceRoot = ".";

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 codex-${asset.target} $out/bin/codex
    tar xzf ${codeModeHost}
    install -m755 codex-code-mode-host-${asset.target} $out/bin/codex-code-mode-host
    wrapProgram $out/bin/codex --add-flags "-c features.daemon_auto_start=false"
    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenAI Codex CLI — coding agent";
    homepage = "https://github.com/openai/codex";
    changelog = "https://github.com/openai/codex/releases/tag/rust-v${version}";
    license = licenses.asl20;
    mainProgram = "codex";
    platforms = builtins.attrNames assets;
  };
}
