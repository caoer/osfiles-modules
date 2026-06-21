# linux/ — server-only home-manager modules (store-copy / rebuild model).
{ configDir }:
{
  imports = [
    ./btop.nix
    (import ./direnv.nix { inherit configDir; })
    ./eza.nix
    (import ./glow.nix { inherit configDir; })
    ./lazygit.nix
    (import ./server-files.nix { inherit configDir; })
  ];
}
