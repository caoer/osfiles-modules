# Codex — OpenAI Codex CLI, the packaged build from npm (@openai/codex
# <version>-<platform>). Pinned ahead of nixpkgs (which lags upstream). Bump:
# update version + sha256 (nix-prefetch-url the tarball URL).
#
# The package is installed whole under $out/lib/codex: codex-package.json,
# bin/ (codex, codex-code-mode-host), codex-path/ (rg) and codex-resources/
# (bwrap, zsh, voice). Codex locates all of them from its own executable; the
# TUI's app-server daemon refuses to start without codex-package.json ("this
# CLI has no complete local package"), and Code Mode fails closed without the
# host binary. The bytes are upstream's: no strip, no patchelf.
{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.160.0";

  assets = {
    "x86_64-linux" = {
      npmPlatform = "linux-x64";
      target = "x86_64-unknown-linux-musl";
      sha256 = "1p2q9kn6zg0b183hj3wxhjync5bsrj871dr7qyw8549rqdhiv91p";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "codex: unsupported platform ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@openai/codex/-/codex-${version}-${asset.npmPlatform}.tgz";
    inherit (asset) sha256;
  };

  sourceRoot = "package/vendor/${asset.target}";

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    test -f codex-package.json
    mkdir -p $out/lib/codex $out/bin
    cp -a . $out/lib/codex/
    ln -s ../lib/codex/bin/codex $out/bin/codex
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
