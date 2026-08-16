# moshi-hook — daemon + CLI for Moshi (https://getmoshi.app), the iOS terminal
# app that drives coding agents over SSH/Mosh/ET. Prebuilt release tarballs from
# the vendor CDN; there is no public source repo to build from.
#
# The Linux binaries are STATICALLY linked Go (verified with `file`), so no
# autoPatchelfHook / nix-ld is needed — unlike the ucc installer's node blobs.
#
# Bump: set version, then refresh all four hashes at once from the vendor's
# own manifest (they are plain sha256 of each tarball, the format fetchurl
# wants):
#   curl -fsSL https://cdn.getmoshi.app/hook/v<version>/checksums.txt
{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "0.2.85";

  assets = {
    "x86_64-linux" = {
      os = "Linux";
      arch = "x86_64";
      sha256 = "5071c6781cb77a158600ab94437af1544e8193208287192dc333c0d57ba4d5b6";
    };
    "aarch64-linux" = {
      os = "Linux";
      arch = "arm64";
      sha256 = "771e288ca939caa43ce7559ad740a9ad2a7474fb755a2df3c7e93616f580860b";
    };
    "x86_64-darwin" = {
      os = "Darwin";
      arch = "x86_64";
      sha256 = "e9c1b61ea181b874e2993041942c5903c28499dc5fbdf1876b9d1d70304a8ffd";
    };
    "aarch64-darwin" = {
      os = "Darwin";
      arch = "arm64";
      sha256 = "b3ba127ee8e57d0a882800e802069711ec4cc7b468b2e3815503617ca42a39a5";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "moshi-hook: unsupported platform ${stdenv.hostPlatform.system}");

in
stdenv.mkDerivation {
  pname = "moshi-hook";
  inherit version;

  src = fetchurl {
    url = "https://cdn.getmoshi.app/hook/v${version}/moshi-hook_${asset.os}_${asset.arch}.tar.gz";
    inherit (asset) sha256;
  };

  # Tarball is flat: moshi-hook, README.md, docs/.
  sourceRoot = ".";

  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/doc/moshi-hook
    install -m755 moshi-hook $out/bin/moshi-hook
    # The vendor installer creates the same alias; `moshi .` is the documented
    # entry point for opening a project tmux session.
    ln -s moshi-hook $out/bin/moshi
    cp -r README.md docs $out/share/doc/moshi-hook/
    runHook postInstall
  '';

  meta = {
    description = "Daemon and CLI for Moshi — agent hooks, approvals, and host gateway";
    homepage = "https://getmoshi.app";
    license = lib.licenses.unfree; # prebuilt vendor binary, no published source
    mainProgram = "moshi-hook";
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
