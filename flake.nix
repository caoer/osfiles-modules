{
  description = "osfiles-modules — shared NixOS modules (golden base + agent profile)";

  # Absorbs agent-flake (deprecated) into a single shared-module flake. Consumers
  # (osfiles, member-nodes-nixos, xu-nixos, leonmax-nixos, …) replace BOTH
  # `inputs.agent` and vendored golden-base files with ONE `inputs.osf-modules`.

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative disk partitioning — consumed by modules/hardware.nix.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Opt-in state on ephemeral root — consumed by modules/external-persist.nix.
    impermanence.url = "github:nix-community/impermanence";

    # Encrypted secrets — consumers wire sops-nix themselves; carried here so
    # they can `inputs.osf-modules.inputs.sops-nix.follows = "sops-nix"`.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # THE central paseo pin for the whole fleet. Transferred from agent-flake.
    # One bump here reaches every consumer that imports this flake.
    paseo = {
      url = "github:getpaseo/paseo/d0189f3f65";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Source-only fetch of osfiles — just the file tree, no flake evaluation.
    # Provides config/ (tool configs: yazi, nvim, tmux, starship, etc.) as a
    # single source of truth. member-home modules reference this instead of
    # bundling a stale copy.
    osfiles-src = {
      url = "git+ssh://git@github.com/caoer/osfiles.git";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      paseo,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # --- Golden base modules (Proxmox VM, btrfs, impermanence) ---
      #
      # disko          ROOT-ONLY btrfs layout (ESP + @/@nix/@home, no @persist)
      # hardware       UEFI + systemd-boot + qemu-guest (closes over disko input)
      # network        DNS + SSH firewall
      # external-persist  impermanence on /persist (closes over impermanence input)
      # golden-base    meta-module importing all four
      #
      # --- Agent profile modules (ucc + claude + paseo + codex) ---
      #
      # agent          NixOS per-user agent profile (closes over paseo input)

      nixosModules = {
        disko = import ./modules/disko.nix;
        hardware = import ./modules/hardware.nix {
          diskoModule = inputs.disko.nixosModules.disko;
        };
        network = import ./modules/network.nix;
        external-persist = import ./modules/external-persist.nix {
          impermanenceModule = inputs.impermanence.nixosModules.impermanence;
        };

        agent = import ./modules/nixos/agent { paseoFlake = paseo; };
        default = self.nixosModules.agent;

        # Convenience meta-module: the complete golden-clone machine layer.
        golden-base =
          { ... }:
          {
            imports = [
              self.nixosModules.disko
              self.nixosModules.hardware
              self.nixosModules.network
              self.nixosModules.external-persist
            ];
          };

        # System-level baseline for semi-managed dev boxes (nix, sshd,
        # fail2ban, nftables, CLI tools, docker). All mkDefault.
        member-base = import ./modules/member-base.nix;
      };

      # Foreign (non-NixOS, system-manager) agent profile system layer.
      systemManagerModules = {
        agent = import ./modules/system-manager/agent { paseoFlake = paseo; };
        default = self.systemManagerModules.agent;
      };

      # Platform-neutral home-manager fragment (ucc paths, claude link, prompts,
      # paseo config, codex). Imported by both NixOS and Foreign/HM-standalone.
      homeModules = {
        agentHome = import ./modules/agent/hm.nix;
        default = self.homeModules.agentHome;
      };

      # HM profile for semi-managed dev boxes: git, aliases, neovim, tmux,
      # yazi, atuin, starship, zoxide, btop, direnv, eza, glow, lazygit,
      # dev toolchains. Config sourced from osfiles (single source of truth).
      homeManagerModules = {
        member-home = import ./modules/member-home {
          configDir = inputs.osfiles-src + "/config";
        };
        default = self.homeManagerModules.member-home;
      };

      # Re-exported packages: paseo (central pin), codex (ahead of nixpkgs),
      # paseo-speech (speech-worker-trace patch). Consumers reference these
      # instead of carrying their own paseo input.
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          paseoPkg = paseo.packages.${system}.paseo;
        in
        {
          paseo = paseoPkg;
          default = paseoPkg;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          codex = pkgs.callPackage ./packages/codex.nix { };
          paseo-speech = paseoPkg.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./packages/paseo-speech-worker-trace.patch ];
          });
        }
      );
    };
}
