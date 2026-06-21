# modules/_all-sm.nix — system-manager (Foreign) modules.
{ paseoFlake }:
{ ... }:
{
  imports = [
    ./ucc/ucc.sm.nix
    (import ./paseo/paseo.sm.nix { inherit paseoFlake; })
  ];
}
