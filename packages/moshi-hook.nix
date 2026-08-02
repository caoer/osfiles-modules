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
  version = "0.2.69";

  assets = {
    "x86_64-linux" = {
      os = "Linux";
      arch = "x86_64";
      sha256 = "3903e2e5d1dba02f9e1f53df8cea6e2b3260e1581461b9a07ca65f18814b8b08";
    };
    "aarch64-linux" = {
      os = "Linux";
      arch = "arm64";
      sha256 = "0a30e081399543551bbd0ba3320f3b28be814a585e5c591e168f8fd6d9565f07";
    };
    "x86_64-darwin" = {
      os = "Darwin";
      arch = "x86_64";
      sha256 = "7cf24d316bafffc59d30e05d6ad6b27d4c03c9953ce901056f57f03c25e4b83b";
    };
    "aarch64-darwin" = {
      os = "Darwin";
      arch = "arm64";
      sha256 = "52258126b675dad210a8f04b83d8e90b359951af37474ff985d2c3f49102d981";
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
