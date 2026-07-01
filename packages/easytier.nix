# EasyTier — mesh VPN. Prebuilt release binaries from upstream GitHub releases.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
}:

let
  version = "2.6.4";

  assets = {
    "x86_64-linux" = {
      url = "https://github.com/EasyTier/EasyTier/releases/download/v${version}/easytier-linux-x86_64-v${version}.zip";
      sha256 = "1mnz15y3bd3v8knmz89gs3jpgpbc8bhifzg4dyk8yrdsxpm5kdk1";
      sourceRoot = "easytier-linux-x86_64";
    };
    "aarch64-darwin" = {
      url = "https://github.com/EasyTier/EasyTier/releases/download/v${version}/easytier-macos-aarch64-v${version}.zip";
      sha256 = "0jvyvzwf1ci44chj98cd3wvpw2carzr9c1dssv0k2vd338nqiqab";
      sourceRoot = "easytier-macos-aarch64";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "easytier: unsupported platform ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "easytier";
  inherit version;

  src = fetchurl {
    inherit (asset) url sha256;
  };

  nativeBuildInputs = [ unzip ];
  inherit (asset) sourceRoot;

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    for bin in easytier-core easytier-cli easytier-web easytier-web-embed; do
      [ -f "$bin" ] && cp "$bin" "$out/bin/$bin" && chmod +x "$out/bin/$bin"
    done
    runHook postInstall
  '';

  meta = with lib; {
    description = "EasyTier — decentralized mesh VPN";
    homepage = "https://github.com/EasyTier/EasyTier";
    changelog = "https://github.com/EasyTier/EasyTier/releases/tag/v${version}";
    license = licenses.asl20;
    platforms = builtins.attrNames assets;
  };
}
