# sing-box — universal proxy platform. Prebuilt binary from upstream GitHub releases.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  version = "1.15.0-alpha.6";

  assets = {
    "x86_64-linux" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-amd64.tar.gz";
      sha256 = "sha256-4ZxeOWGucH12LcPmI2GGwz8Kr5ETBWcHjhsq8UjNoK4=";
      sourceRoot = "sing-box-${version}-linux-amd64";
    };
    "aarch64-linux" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-arm64.tar.gz";
      sha256 = "sha256-7nV4cHP+Ubmzxph97TYZjrG3encUR7DCh93mIgOSRbQ=";
      sourceRoot = "sing-box-${version}-linux-arm64";
    };
    "aarch64-darwin" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-darwin-arm64.tar.gz";
      sha256 = "sha256-8d29rxOCOn6F17c1K1SdM1MFQYxumHG5YPH4IKtOAIs=";
      sourceRoot = "sing-box-${version}-darwin-arm64";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "sing-box: unsupported platform ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "sing-box";
  inherit version;

  src = fetchurl {
    inherit (asset) url sha256;
  };

  inherit (asset) sourceRoot;

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp sing-box $out/bin/sing-box
    chmod +x $out/bin/sing-box
    runHook postInstall
  '';

  meta = with lib; {
    description = "sing-box — universal proxy platform";
    homepage = "https://github.com/SagerNet/sing-box";
    changelog = "https://github.com/SagerNet/sing-box/releases/tag/v${version}";
    license = licenses.gpl3Plus;
    platforms = builtins.attrNames assets;
  };
}
