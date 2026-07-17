# kimi-code — Moonshot AI terminal agent CLI (prebuilt binary).
# PINNED to 0.27.0: tracks https://code.kimi.com/kimi-code/latest.
# Bump `version` + platform hashes from the release manifest on each update:
#   https://code.kimi.com/kimi-code/binaries/<ver>/manifest.json
{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.27.0";

  # Manifest platform keys → nix system + SRI hashes (sha256 of the raw binary).
  assets = {
    "aarch64-darwin" = {
      platform = "darwin-arm64";
      hash = "sha256-VQvKC6bkdPTg+urfrgOpKUx8JWiGcPOP9IirjPF22Bc=";
    };
    "x86_64-darwin" = {
      platform = "darwin-x64";
      hash = "sha256-EaAQ/t+jYYlPZvE8ijnuOv33r0CfcmBV8kxV5KSHb5E=";
    };
    "aarch64-linux" = {
      platform = "linux-arm64";
      hash = "sha256-R2al6jO+sbIGbdlxLH8CxukbUQxModEX8xovicLfoCQ=";
    };
    "x86_64-linux" = {
      platform = "linux-x64";
      hash = "sha256-7surRbwbmStkjEY4eglyw0D6x9iyVJYW8erOyQ5ZWjE=";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "kimi-code: unsupported platform ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "kimi-code";
  inherit version;

  src = fetchurl {
    url = "https://code.kimi.com/kimi-code/binaries/${version}/kimi-code-${asset.platform}";
    inherit (asset) hash;
  };

  dontUnpack = true;
  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 $src $out/bin/kimi
    runHook postInstall
  '';

  meta = with lib; {
    description = "Kimi Code CLI — Moonshot AI terminal agent";
    homepage = "https://github.com/MoonshotAI/kimi-code";
    changelog = "https://code.kimi.com/kimi-code/binaries/${version}/manifest.json";
    license = licenses.mit; # upstream https://github.com/MoonshotAI/kimi-code
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    platforms = builtins.attrNames assets;
    mainProgram = "kimi";
  };
}
