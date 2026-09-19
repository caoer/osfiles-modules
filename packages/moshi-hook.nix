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
  version = "0.3.26";

  assets = {
    "x86_64-linux" = {
      os = "Linux";
      arch = "x86_64";
      sha256 = "0241614ab88282159800caf9a0a65230b8e927e21f02a6d34ecc2cfedc782550";
    };
    "aarch64-linux" = {
      os = "Linux";
      arch = "arm64";
      sha256 = "d105703fb053e6af416e7b9ca9d8ce3b1fb488443585a1c5ea45fd392ba48118";
    };
    "x86_64-darwin" = {
      os = "Darwin";
      arch = "x86_64";
      sha256 = "76865e5b107966a0acea97e0e9be1e3db2c06930cd6406672a85987569419364";
    };
    "aarch64-darwin" = {
      os = "Darwin";
      arch = "arm64";
      sha256 = "b464d16b122ace5c8c34288a717995b4f743e3961cfa9261b5ba8b6163d7e6dc";
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
