# linux/ — server-only home-manager modules (store-copy / rebuild model).
{
  imports = [
    ./btop.nix
    ./direnv.nix
    ./eza.nix
    ./glow.nix
    ./lazygit.nix
    ./server-files.nix
  ];
}
