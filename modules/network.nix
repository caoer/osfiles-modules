# modules/network.nix — generic. Networking is owned by
# external-persist.nix's staticNetwork feature (systemd-networkd): a clone reads its
# address from the seeded /persist (IP-as-identity), falling back to DHCP when no
# static.conf is present. So no useDHCP here — just DNS + the ssh firewall port.
{ lib, config, ... }: {
  networking = {
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    firewall.allowedTCPPorts = [ 22 ];
  };

  # Propagate root's authorized keys into initrd SSH (for remote unlock)
  boot.initrd.network.ssh.authorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;

  services.openssh = {
    enable = true;

    settings = {
      X11Forwarding = false;
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      UseDns = false;
      # Unbind gnupg sockets if they exist
      StreamLocalBindUnlink = true;
      PermitRootLogin = "prohibit-password";
    };

    # Only allow system-level authorized_keys to avoid injections
    authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
  };

  programs.ssh.knownHosts = {
    "github.com" = {
      hostNames = [ "github.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };

    "gitlab.com" = {
      hostNames = [ "gitlab.com" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";
    };

    "codeberg.org" = {
      hostNames = [ "codeberg.org" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVIC02vnjFyL+I4RHfvIGNtOgJMe769VTF1VR4EB3ZB";
    };

    "gitea.c3d2.de" = {
      hostNames = [ "gitea.c3d2.de" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO8Q7kGF3Hh6HvmlSIgZOjgoIZRpyxKvMBTcPWHlecuh";
    };
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
