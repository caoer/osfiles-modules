# kimi-code — Moonshot AI terminal agent CLI (prebuilt binary).
# PINNED to 0.29.0: tracks https://code.kimi.com/kimi-code/latest.
# Bump `version` + platform hashes from the release manifest on each update:
#   https://code.kimi.com/kimi-code/binaries/<ver>/manifest.json
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  version = "0.29.0";

  # Manifest platform keys → nix system + SRI hashes (sha256 of the raw binary).
  assets = {
    "aarch64-darwin" = {
      platform = "darwin-arm64";
      hash = "sha256-XMz1NgTyDFSZ6hDDCUKY9Joa1Z+pDN3Z/X4LpEgV/dM=";
    };
    "x86_64-darwin" = {
      platform = "darwin-x64";
      hash = "sha256-r9HIW7K3c1GBzrBsg3CHX2NlIDSoy284RcwrCdKsGJw=";
    };
    "aarch64-linux" = {
      platform = "linux-arm64";
      hash = "sha256-YziJj43Wf5+CP8AFTBQs3goeLR0eLrzts0Oty4FlOUo=";
    };
    "x86_64-linux" = {
      platform = "linux-x64";
      hash = "sha256-RPCu1YZVeQt4/orBv0Qhfz/A5ll3q7dCb57cqUPdxEQ=";
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
  # Bun-compiled single-file executable: the JS bundle is embedded in the
  # binary — stripping corrupts it.
  dontStrip = true;

  # The prebuilt ELF targets generic linux (/lib64 interpreter, glibc,
  # libstdc++) — NixOS refuses it unpatched ("Could not start dynamically
  # linked executable"). autoPatchelfHook rewrites interpreter + rpath.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ (lib.getLib stdenv.cc.cc) ];

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
