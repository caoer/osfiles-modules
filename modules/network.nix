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

  # OpenSSH 10.3 regression: the new sshd-auth subprocess drops privileges
  # before reading /etc/ssh/authorized_keys.d/%u. NixOS sets /etc/ssh to 700,
  # so non-root key lookup silently fails. 711 lets the auth subprocess
  # traverse the directory without exposing host key contents (keys stay 600).
  systemd.tmpfiles.rules = [
    "d /etc/ssh 0711 root root -"
  ];
}
