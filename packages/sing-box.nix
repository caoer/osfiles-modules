# sing-box — universal proxy platform. Prebuilt binary from upstream GitHub releases.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  version = "1.14.0-alpha.23";

  assets = {
    "x86_64-linux" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-amd64.tar.gz";
      sha256 = "009kwzasxh1mz1j5vmi0vn6zrakilcz0xx9j6s9hmliwpfdbg59m";
      sourceRoot = "sing-box-${version}-linux-amd64";
    };
    "aarch64-linux" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-arm64.tar.gz";
      sha256 = "1f1j6lij0zf4gi4dbw52qcirlj8cpnwy8nbx32dpa9in7701hbd3";
      sourceRoot = "sing-box-${version}-linux-arm64";
    };
    "aarch64-darwin" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-darwin-arm64.tar.gz";
      sha256 = "1hl8y7463n2vd0b2rnq8gljyi0w7h4d0b4vrpj1rgyzghjck1inj";
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
