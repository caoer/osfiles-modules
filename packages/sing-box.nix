# sing-box — universal proxy platform. Prebuilt binary from upstream GitHub releases.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  version = "1.15.0-alpha.9";

  assets = {
    "x86_64-linux" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-amd64.tar.gz";
      sha256 = "sha256-iu3h9ZNahW2TnGFBNnfcLn4+sARu+8IrmoaSKebaJ58=";
      sourceRoot = "sing-box-${version}-linux-amd64";
    };
    "aarch64-linux" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-arm64.tar.gz";
      sha256 = "sha256-eKSn/FiMR9gQ+oR16M6/Vrr9xMIcvQG8/jE/q/xV5Qc=";
      sourceRoot = "sing-box-${version}-linux-arm64";
    };
    "aarch64-darwin" = {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-darwin-arm64.tar.gz";
      sha256 = "sha256-rfFCfd7VNpZSbZDjk5JGFRZwnl2aeHFSPYDU/pAk6HE=";
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
