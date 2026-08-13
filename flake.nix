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
    # Pin a release tag — floating `main` shipped 0.3.0 without node-pty
    # prebuilds (terminal worker crash). Wrapper in packages/paseo.nix
    # asserts/injects pty.node so a future tracer regression fails the build.
    paseo = {
      url = "github:getpaseo/paseo/v0.3.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NixVim (cnixvim) — thin wrapper over caoer/nixvim (khanelivim fork).
    # Do NOT follow nixpkgs — cnixvim lets khanelivim use its own nixpkgs.
    cnixvim.url = "github:caoer/cnixvim";

    # tmux source — caoer/tmux fork master: upstream post-3.7b (the
    # PANE_REDRAW-on-?2026l image-erasing regression is removed there) plus
    # the zt patches. Built by packages/tmux.nix — see that file for the full
    # root-cause story. Bump this rev to pull newer upstream via the fork.
    tmux-src = {
      url = "github:caoer/tmux/05a934ebdb590387d4f1454d9d380b77f35cf711";
      flake = false;
    };

    # Pinned nixpkgs for yazi 26.5.6 — same rev osfiles / the fleet run.
    # modules/yazi/config targets the 26.5.6 schema (group fetchers + git
    # plugin @since 26.5.6). Consumer nixpkgs often still ships 26.1.22, which
    # rejects the config (`missing field id in prepend_fetchers`) and refuses
    # the git plugin. Deliberately NO `follows` — the pin is the point.
    nixpkgs-yazi.url = "github:NixOS/nixpkgs/9ae611a455b90cf061d8f332b977e387bda8e1ca";
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
        member-base = import ./modules/member-base.nix { tmuxSrc = inputs.tmux-src; };

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
        default = import ./modules/_all-nixos.nix {
          paseoFlake = paseo;
          tmuxSrc = inputs.tmux-src;
        };
      };

      # Foreign (non-NixOS, system-manager) modules.
      systemManagerModules = {
        default = import ./modules/_all-sm.nix { paseoFlake = paseo; };
      };

      # HM modules: all tool modules (opt-in via osf.<tool>.enable) + presets.
      homeManagerModules = {
        default = import ./modules/_all-hm.nix {
          cnixvimFlake = cnixvim;
          nixpkgsYazi = inputs.nixpkgs-yazi;
        };
        dev-box = import ./presets/dev-box.nix;
      };

      # Re-exported packages: paseo (central pin), codex (ahead of nixpkgs).
      # Consumers reference these instead of carrying their own paseo input.
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
          paseoPkg = pkgs.callPackage ./packages/paseo.nix {
            paseo = paseo.packages.${system}.paseo;
          };
        in
        {
          paseo = paseoPkg;
          default = paseoPkg;
          kimi-code = pkgs.callPackage ./packages/kimi-code.nix { };
          # Prebuilt vendor binary, all four systems — exposed so a host can
          # reference it directly and so CI can push it to the cache.
          moshi-hook = pkgs.callPackage ./packages/moshi-hook.nix { };
          # The fleet's tmux. Exposed so .woodpecker.yml can build the exact
          # derivation member-base installs and push it to cache.0xtau.com.
          tmux = pkgs.callPackage ./packages/tmux.nix { inherit (inputs) tmux-src; };
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          codex = pkgs.callPackage ./packages/codex.nix { };
          metacubexd = pkgs.callPackage ./packages/metacubexd.nix { };
          watchdog = pkgs.callPackage ./packages/watchdog.nix { };
        }
      );
    };
}
