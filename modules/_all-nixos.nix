# modules/_all-nixos.nix — NixOS-level modules: member-base + agent profiles.
# Golden base (disko, hardware, network, external-persist) is imported separately
# via nixosModules.golden-base — it requires closed flake inputs.
{
  paseoFlake,
  tmuxSrc,
  herdrEternalFlake,
}:
{ ... }:
{
  imports = [
    (import ./member-base.nix { inherit tmuxSrc; })
    ./media-tools.nix
    ./ucc/ucc.nixos.nix
    (import ./paseo/paseo.nixos.nix { inherit paseoFlake; })
    # Convenience profile: osf.agent.enable → wires ucc + paseo with defaults.
    ./agent/agent.nixos.nix
    ./sing-box-client/sing-box-client.nixos.nix
    ./sing-box-gateway/sing-box-gateway.nixos.nix
    ./ucc-singbox/ucc-singbox.nixos.nix
    ./moshi/moshi.nixos.nix
    (import ./herdr-eternal/herdr-eternal.nixos.nix { inherit herdrEternalFlake; })
  ];
}
