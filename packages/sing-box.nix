# sing-box — universal proxy platform. Prebuilt binary from upstream GitHub releases.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  version = "1.14.0-alpha.35";

  assets = {
    "x86_64-linux" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-amd64.tar.gz";
      sha256 = "15qy8q330364c10dzp821fzkmanf803xv86z2ac0jm7n9863xvdm";
      sourceRoot = "sing-box-${version}-linux-amd64";
    };
    "aarch64-linux" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-arm64.tar.gz";
      sha256 = "15wvzvsmc0hmh9qfp2rx7h6xg8r8s5b19vfmpm2sk8x7qn57n9gq";
      sourceRoot = "sing-box-${version}-linux-arm64";
    };
    "aarch64-darwin" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-darwin-arm64.tar.gz";
      sha256 = "08l494zhqbb1cz4p4kvzbabv2cg18lv2d9hrr3773wd3nhk9fdsr";
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
