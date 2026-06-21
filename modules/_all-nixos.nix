# modules/_all-nixos.nix — NixOS-level modules: member-base + agent profiles.
# Golden base (disko, hardware, network, external-persist) is imported separately
# via nixosModules.golden-base — it requires closed flake inputs.
{ paseoFlake }:
{ ... }:
{
  imports = [
    ./member-base.nix
    ./ucc/ucc.nixos.nix
    (import ./paseo/paseo.nixos.nix { inherit paseoFlake; })
  ];
}
