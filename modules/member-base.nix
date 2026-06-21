# modules/member-base.nix — system-level NixOS baseline for semi-managed dev boxes.
#
# Combines: base settings (nix, sshd, fail2ban, nftables, zsh), CLI tools,
# and docker. All values use lib.mkDefault so per-owner repos can override.
{ lib, pkgs, ... }:
{
  # --- Nix daemon settings ---
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = lib.mkDefault true;
    };
    gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      options = lib.mkDefault "--delete-older-than 14d";
    };
    optimise.automatic = lib.mkDefault true;
  };

  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
  time.timeZone = lib.mkDefault "UTC";

  # --- Services ---
  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = lib.mkDefault "prohibit-password";
        PasswordAuthentication = lib.mkDefault false;
        KbdInteractiveAuthentication = lib.mkDefault false;
        X11Forwarding = false;
        UseDns = false;
        # Clean stale gpg-agent / ssh-agent sockets on reconnect
        StreamLocalBindUnlink = true;
      };
      ports = lib.mkDefault [ 22 ];
      # System-managed authorized_keys only — prevents rogue ~/.ssh/authorized_keys injections.
      authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
    };
    fail2ban.enable = lib.mkDefault true;
    qemuGuest.enable = lib.mkDefault true;
  };

  # Pin host keys for common forges — eliminates TOFU prompts and MITM surface.
  programs.ssh.knownHosts = {
    "github.com".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    "gitlab.com".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";
    "codeberg.org".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVIC02vnjFyL+I4RHfvIGNtOgJMe769VTF1VR4EB3ZB";
  };

  networking.nftables.enable = lib.mkDefault true;
  programs.zsh.enable = true;

  # --- System packages: recovery toolkit + CLI tools ---
  environment.systemPackages = with pkgs; [
    # Recovery toolkit
    vim
    curl
    git
    htop
    openssl

    # Multiplexer + sessions
    tmux
    sesh

    # Version control
    gh
    tig

    # Network / download
    aria2

    # Build / task runners
    gnumake
    just

    # Languages (system-level; toolchains live in the HM dev profile)
    python3

    # Modern CLI
    eza
    fd
    jq
    yq-go
    btop
    ncdu
    duf
    dust
    ripgrep
    glow
    gum
    direnv

    # Secrets
    sops
    age

    # Media — yazi A/V preview plugins call /run/current-system/sw/bin/ffmpeg
    # by absolute path, so ffmpeg must be a system package, not home.packages.
    ffmpeg

    # Containers
    docker-compose
  ];

  # --- Docker ---
  virtualisation.docker = {
    enable = lib.mkDefault true;
    autoPrune = {
      enable = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
    };
    daemon.settings = {
      # Safe defaults — clear of common mesh CIDRs and VM LANs.
      bip = lib.mkDefault "10.250.0.1/24";
      default-address-pools = lib.mkDefault [
        {
          base = "10.251.0.0/16";
          size = 24;
        }
      ];
    };
  };

  networking.firewall.trustedInterfaces = lib.mkDefault [ "docker0" ];
}
