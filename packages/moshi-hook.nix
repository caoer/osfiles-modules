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
  version = "0.2.68";

  assets = {
    "x86_64-linux" = {
      os = "Linux";
      arch = "x86_64";
      sha256 = "e3c92d52e8a8eeb107ca8a8f9314ac8dc4322fa45348cce61881b9e52172c97c";
    };
    "aarch64-linux" = {
      os = "Linux";
      arch = "arm64";
      sha256 = "1dcce34460ec5663e008f932259fb1dcf92335775afcfe0483b3ca859de882cb";
    };
    "x86_64-darwin" = {
      os = "Darwin";
      arch = "x86_64";
      sha256 = "2ccf85cc332ba29352017ee2d5498d780b1c8753f8b0f41c7acbaea8615908a0";
    };
    "aarch64-darwin" = {
      os = "Darwin";
      arch = "arm64";
      sha256 = "20402e71bac06ab250a73bde5b9c9e4b6946ff4c016ddda9f20c9e22208f0fb5";
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
