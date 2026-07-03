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
      url = "github:getpaseo/paseo";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NixVim (cnixvim) — thin wrapper over caoer/nixvim (khanelivim fork).
    # Do NOT follow nixpkgs — cnixvim lets khanelivim use its own nixpkgs.
    cnixvim.url = "github:caoer/cnixvim";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      paseo,
      cnixvim,
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
      nixosModules = {
        disko = import ./modules/disko.nix;
        hardware = import ./modules/hardware.nix {
          diskoModule = inputs.disko.nixosModules.disko;
        };
        network = import ./modules/network.nix;
        external-persist = import ./modules/external-persist.nix {
          impermanenceModule = inputs.impermanence.nixosModules.impermanence;
        };

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

        # System-level baseline for semi-managed dev boxes.
        member-base = import ./modules/member-base.nix;

        # --- Mesh/network subsystem (extracted from osfiles) ---
        # These take an `osfLib` module arg: consumers inject their private
        # data (wellKnown, networks, mesh registry, singBoxUpstreams) plus
        # this flake's lib helpers via `_module.args.osfLib`. NOT part of
        # `default` — importing them without osfLib fails eval by design.
        osf-network = import ./modules/net/network.nix;
        osf-easytier = import ./modules/net/easytier.nix;
        osf-tailscale = import ./modules/net/tailscale.nix;
        osf-gateway = import ./modules/net/gateway;

        # Default: member-base + agent NixOS modules (ucc, paseo).
        default = import ./modules/_all-nixos.nix { paseoFlake = paseo; };
      };

      # Foreign (non-NixOS, system-manager) modules.
      systemManagerModules = {
        default = import ./modules/_all-sm.nix { paseoFlake = paseo; };
      };

      # HM modules: all tool modules (opt-in via osf.<tool>.enable) + presets.
      homeManagerModules = {
        default = import ./modules/_all-hm.nix { cnixvimFlake = cnixvim; };
        dev-box = import ./presets/dev-box.nix;
      };

      # Re-exported packages: paseo (central pin), codex (ahead of nixpkgs),
      # paseo-speech (speech-worker-trace patch). Consumers reference these
      # instead of carrying their own paseo input.
      # Shared lib — importable by consumers.
      lib = {
        mkSingBoxService = import ./lib/mkSingBoxService.nix;
        singboxConfigGenerator = import ./lib/singbox-config-generator.nix;
        mkEasytierStartScript = import ./lib/mkEasytierStartScript.nix;
        easytierTailscaleFix = import ./lib/easytierTailscaleFix.nix;
        mkSsOutbound = import ./lib/mkSsOutbound.nix;
        # Universal network constants (public DNS resolvers, RFC1918, CGNAT,
        # magic-DNS addresses) — safe-public, shared by all consumers.
        wellKnown = import ./lib/well-known.nix;
        # Cross-platform net tuning — a { platform } function returning a
        # module: (netTuning { platform = "linux"; }) / "darwin".
        netTuning = import ./modules/net/net-tuning.nix;
      };

      # Overlay: adds metacubexd, watchdog to pkgs.
      overlays.default = final: prev: {
        metacubexd = final.callPackage ./packages/metacubexd.nix { };
        watchdog = final.callPackage ./packages/watchdog.nix { };
      };

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
          metacubexd = pkgs.callPackage ./packages/metacubexd.nix { };
          watchdog = pkgs.callPackage ./packages/watchdog.nix { };
          paseo-speech = paseoPkg.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./packages/paseo-speech-worker-trace.patch ];
          });
        }
      );
    };
}
