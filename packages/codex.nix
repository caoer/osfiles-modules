# Codex — OpenAI Codex CLI. Prebuilt static musl binaries from GitHub releases.
# Pinned ahead of nixpkgs (which lags upstream). Bump: update version + both
# sha256 (nix-prefetch-url each tarball URL).
#
# Two tarballs per release: the CLI and codex-code-mode-host. Codex resolves
# the host beside its own binary and fails closed without it ("Code Mode is
# unavailable … host executable was not found").
{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.154.0";

  assets = {
    "x86_64-linux" = {
      target = "x86_64-unknown-linux-musl";
      sha256 = "00kzq045shxniy3djd6nxp4xnj7gvs89xviibwpj93xfjwjqpqfp";
      codeModeHostSha256 = "1xq1mx0xd1jb4nhk64yx98ikmiv1vvvpsrvmw76sfv9wlb6gg3d6";
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

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 codex-${asset.target} $out/bin/codex
    tar xzf ${codeModeHost}
    install -m755 codex-code-mode-host-${asset.target} $out/bin/codex-code-mode-host
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
