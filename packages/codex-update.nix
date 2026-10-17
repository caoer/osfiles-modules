# codex-update — the user-level codex installer the ucc module's codex-update
# user unit runs (osf.ucc.codex.install = "user"). It lands the same npm
# platform tree packages/codex.nix builds, under ~/.local/share/codex/<version>,
# with no nix on the update path; the script's header has the contract.
{
  lib,
  stdenv,
  writeShellApplication,
  coreutils,
  curl,
  gnutar,
  gzip,
  jq,
  openssl,
}:

let
  targets = {
    "x86_64-linux" = {
      platform = "linux-x64";
      target = "x86_64-unknown-linux-musl";
    };
    "aarch64-linux" = {
      platform = "linux-arm64";
      target = "aarch64-unknown-linux-musl";
    };
  };
  t =
    targets.${stdenv.hostPlatform.system}
      or (throw "codex-update: unsupported platform ${stdenv.hostPlatform.system}");
in
writeShellApplication {
  name = "codex-update";
  runtimeInputs = [
    coreutils
    curl
    gnutar
    gzip
    jq
    openssl
  ];
  text = ''
    platform=${lib.escapeShellArg t.platform}
    target=${lib.escapeShellArg t.target}
  ''
  + builtins.readFile ./codex-update.sh;
  meta.platforms = builtins.attrNames targets;
}
