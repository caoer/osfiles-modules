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

  # OpenSSH 10.3 regression: sshd-auth subprocess drops privileges before
  # reading /etc/ssh/authorized_keys.d/%u. NixOS activation sets /etc/ssh to
  # 700, blocking non-root key lookup. An activationScript (not tmpfiles —
  # activation resets perms after tmpfiles runs) sets 711 so sshd-auth can
  # traverse without exposing host key contents (keys stay 600).
  system.activationScripts.sshDirPerms = {
    deps = [ "etc" ];
    text = ''
      chmod 711 /etc/ssh
    '';
  };
}
