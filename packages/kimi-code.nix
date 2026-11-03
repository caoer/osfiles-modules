# kimi-code — Moonshot AI terminal agent CLI (prebuilt binary).
# PINNED to 2.1.1: tracks https://code.kimi.com/kimi-code/latest.
# Bump `version` + platform hashes from the release manifest on each update:
#   https://code.kimi.com/kimi-code/binaries/<ver>/manifest.json
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  patchelf,
}:

let
  # patchelf 0.18 and 0.19 write an ELF this Bun-compiled binary cannot load:
  # it dies with SIGSEGV inside ld.so before main, on any glibc. 0.15.2
  # patches the same binary into one that runs. Every patchelf call in the
  # build (autoPatchelfHook, the fixup's shrink-rpath) resolves `patchelf`
  # on PATH, so preFixup puts this one first.
  patchelfForBun = patchelf.overrideAttrs (_: {
    version = "0.15.2";
    src = fetchurl {
      url = "https://github.com/NixOS/patchelf/releases/download/0.15.2/patchelf-0.15.2.tar.bz2";
      hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
    };
    patches = [ ];
    doCheck = false;
  });

  version = "2.1.1";

  # Manifest platform keys → nix system + SRI hashes (sha256 of the raw binary).
  assets = {
    "aarch64-darwin" = {
      platform = "darwin-arm64";
      hash = "sha256-S6tvlsLCiTaLfwWgT2ZzfFOlnOdA+TLY8UkkBYR1jvs=";
    };
    "x86_64-darwin" = {
      platform = "darwin-x64";
      hash = "sha256-7TIVr27riXnJnb4HYUhO2PCBmO8PbKF4Vjf2CxRjypU=";
    };
    "aarch64-linux" = {
      platform = "linux-arm64";
      hash = "sha256-i8wKImeg7LH/SMrShPfjZFKKAVmPONaW7BuqawaaiMg=";
    };
    "x86_64-linux" = {
      platform = "linux-x64";
      hash = "sha256-ZvR1NuQLArsdV3zdMkdo9z05uLlHLgyhQOc9jiJc194=";
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
  preFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    export PATH=${patchelfForBun}/bin:$PATH
  '';

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
