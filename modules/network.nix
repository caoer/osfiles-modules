# modules/network.nix — generic. Networking is owned by
# external-persist.nix's staticNetwork feature (systemd-networkd): a clone reads its
# address from the seeded /persist (IP-as-identity), falling back to DHCP when no
# static.conf is present. So no useDHCP here — just DNS + the ssh firewall port.
_: {
  networking = {
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    firewall.allowedTCPPorts = [ 22 ];
  };
}
