# MosDNS — pluggable DNS forwarder/dispatcher. Prebuilt binary from GitHub releases.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
}:

let
  version = "5.3.4";
  url = "https://github.com/IrineSistiana/mosdns/releases/download/v${version}/mosdns-linux-amd64.zip";

  sha256 = {
    "linux-amd64" = "119fsxybf9x5b00vcnl6iydixb45kc2bbnkqrb6b37kqh0qcgg1s";
  };

in
stdenv.mkDerivation {
  pname = "mosdns";
  inherit version;

  src = fetchurl {
    inherit url;
    sha256 = sha256."linux-amd64";
  };

  nativeBuildInputs = [ unzip ];

  sourceRoot = ".";

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp mosdns $out/bin/mosdns
    chmod +x $out/bin/mosdns
    runHook postInstall
  '';

  meta = with lib; {
    description = "MosDNS — pluggable DNS forwarder/dispatcher";
    homepage = "https://github.com/IrineSistiana/mosdns";
    changelog = "https://github.com/IrineSistiana/mosdns/releases/tag/v${version}";
    license = licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
  };
}
