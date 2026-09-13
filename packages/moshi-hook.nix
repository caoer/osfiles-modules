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
  version = "0.3.22";

  assets = {
    "x86_64-linux" = {
      os = "Linux";
      arch = "x86_64";
      sha256 = "4031728e9f71bb59d49bba7a2db2d260049ee14ddcf6d63e70e5c82f88d8fdda";
    };
    "aarch64-linux" = {
      os = "Linux";
      arch = "arm64";
      sha256 = "ee92dfb18f293a0bf2b944e446541c7bc59ad209ebced393150e639ad879a875";
    };
    "x86_64-darwin" = {
      os = "Darwin";
      arch = "x86_64";
      sha256 = "0334fded7d237f4dbe2b804927286ee1ca56bdc5581cd520056d0e193cc876a1";
    };
    "aarch64-darwin" = {
      os = "Darwin";
      arch = "arm64";
      sha256 = "5d8d671a63a5178bb35f64bd2e0d0b7d3fee66b8096188d062ab8eeca4e4bd0f";
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
