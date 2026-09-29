# modules/_all-sm.nix — system-manager (Foreign) modules.
{ ... }:
{
  imports = [
    ./ucc/ucc.sm.nix
    ./paseo/paseo.sm.nix
  ];
}
