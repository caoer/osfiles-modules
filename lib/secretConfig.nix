# lib/secretConfig.nix — config files that may carry sops-nix placeholders.
#
# A credential option set to `placeholder "<secret>"` (the secret declared in
# sops.secrets) puts a sops-nix placeholder into the module's config text. A
# module that writes a config file checks that text with hasPlaceholder: text
# with one is declared as a `sops.templates.<name>` entry, which sops-nix writes
# root-only under /run/secrets-rendered at activation with each placeholder
# replaced by the decrypted value, so the credential never reaches the Nix
# store. Text without one is written to the store as before, so its path and
# bytes do not change.
#
# placeholder returns the same string as `config.sops.placeholder.<secret>`.
# Use it for these options: sops-nix defines config.sops.placeholder only when
# sops.templates is non-empty, so reading it here would loop through the
# hasPlaceholder check that decides whether the template exists.
{ lib }:
{
  placeholder = name: "<SOPS:${builtins.hashString "sha256" name}:PLACEHOLDER>";
  hasPlaceholder = text: lib.hasInfix "<SOPS:" text;
}
