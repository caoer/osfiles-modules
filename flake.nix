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

    # THE central herdr pin for the whole fleet (agent terminal multiplexer),
    # paired with modules/herdr — one binary AND one config.toml everywhere.
    # Our fork: upstream release + CI, nix shell completions and a macOS
    # double-Escape fix, built by the fork's Woodpecker pipeline and
    # served from cache.0xtau.com. Deliberately NO `inputs.nixpkgs.follows`:
    # the cached closure is keyed on the fork's own lock, and a follows here
    # means every host compiles Rust + zig again. osfiles pins the same URL;
    # keep both locks on one rev or `herdr --remote` re-bootstraps on a
    # version mismatch. To bump: rebase the fork's main on the new upstream
    # tag, push, `nix flake update herdr` here and in osfiles.
    herdr.url = "git+https://git.0xdao.app/caoer115/herdr?ref=main&shallow=1";

    # cvim — the fleet's nvim distro (osf.cvim). The same flake the mac
    # installs through `nix profile` and osfiles ships to every server tier,
    # so one source builds the editor on every host.
    # Do NOT follow nixpkgs — cvim rides nixvim's own nixpkgs.
    cvim.url = "github:caoer/cvim";

    # tmux source — caoer/tmux fork master: upstream post-3.7b (the
    # PANE_REDRAW-on-?2026l image-erasing regression is removed there) plus
    # the zt patches. Built by packages/tmux.nix — see that file for the full
    # root-cause story. Bump this rev to pull newer upstream via the fork.
    tmux-src = {
      url = "github:caoer/tmux/05a934ebdb590387d4f1454d9d380b77f35cf711";
      flake = false;
    };

    # THE central hunk pin for the whole fleet — review-first terminal diff
    # viewer for agent-authored changesets (`hunk diff A B`, `hunk show`,
    # `hunk patch`; also usable as git pager/difftool). Same tag osfiles pins
    # in its own flake.nix, so mac and member hosts run one version.
    #
    # Our nixpkgs (d407951) has NO `hunk` attribute at all — nix answers the
    # eval with "did you mean chunk, honk, hunt" — so the upstream flake is
    # the only source without a nixpkgs bump.
    #
    # Deliberately NO `inputs.nixpkgs.follows`: upstream pins its own nixpkgs
    # plus a `systems` triplet for bun2nix, and overriding it breaks their
    # eval guards. That triplet is why the re-export below is guarded —
    # upstream builds aarch64-darwin/aarch64-linux/x86_64-linux and NOT
    # x86_64-darwin, which IS in this flake's `systems`. Unguarded, every
    # `nix flake show`/`check` would fail on that system.
    hunk.url = "github:modem-dev/hunk/v0.18.2";

    # Pinned nixpkgs for yazi 26.9.1 — same rev osfiles / the fleet run.
    # modules/yazi/config targets the 26.9.1 schema (yazi-rs/plugins 4dc7f1b:
    # git plugin @since 26.8.15, rt.term.light() as a function, copy dirpath).
    # A lagging consumer nixpkgs rejects the config (`missing field id in
    # prepend_fetchers`) and refuses the plugins. Deliberately NO `follows` —
    # the pin is the point.
    nixpkgs-yazi.url = "github:NixOS/nixpkgs/da39501c8d0a093136854eddcd6927c8a8bb0d8f";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      cvim,
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
          tmuxSrc = inputs.tmux-src;
        };
      };

      # Foreign (non-NixOS, system-manager) modules.
      systemManagerModules = {
        default = import ./modules/_all-sm.nix;
      };

      # HM modules: all tool modules (opt-in via osf.<tool>.enable) + presets.
      homeManagerModules = {
        default = import ./modules/_all-hm.nix {
          cvimFlake = cvim;
          nixpkgsYazi = inputs.nixpkgs-yazi;
          herdrFlake = inputs.herdr;
          hunkFlake = inputs.hunk;
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
        # placeholder / hasPlaceholder: a credential option that holds a sops
        # placeholder makes its config a sops template (lib/secretConfig.nix).
        secretConfig = import ./lib/secretConfig.nix { inherit (nixpkgs) lib; };
        # Universal network constants (public DNS resolvers, RFC1918, CGNAT,
        # magic-DNS addresses) — safe-public, shared by all consumers.
        wellKnown = import ./lib/well-known.nix;
        # Cross-platform net tuning — a { platform } function returning a
        # module: (netTuning { platform = "linux"; }) / "darwin".
        netTuning = import ./modules/net/net-tuning.nix;
      };

      # Overlay: adds metacubexd, sing-box-dashboard to pkgs.
      overlays.default = final: prev: {
        metacubexd = final.callPackage ./packages/metacubexd.nix { };
        sing-box-dashboard = final.callPackage ./packages/sing-box-dashboard.nix { };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          kimi-code = pkgs.callPackage ./packages/kimi-code.nix { };
          # The fleet's tmux. Exposed so .woodpecker.yml can build the exact
          # derivation member-base installs and push it to cache.0xtau.com.
          tmux = pkgs.callPackage ./packages/tmux.nix { inherit (inputs) tmux-src; };
        }
        // nixpkgs.lib.optionalAttrs (inputs.hunk.packages ? ${system}) {
          # hunk — central fleet pin, re-exported straight from upstream (no
          # wrapper). Consumers put it in home.packages the way they do paseo:
          #   inputs.osf-modules.packages.${pkgs.stdenv.hostPlatform.system}.hunk
          # Guard is upstream's system set, not ours — see the input comment.
          hunk = inputs.hunk.packages.${system}.default;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") rec {
          # THE central paseo pin for the whole fleet — upstream's Linux x64
          # release; bump `version` + `hash` in packages/paseo.nix.
          paseo = pkgs.callPackage ./packages/paseo.nix { };
          default = paseo;
          codex = pkgs.callPackage ./packages/codex.nix { };
          metacubexd = pkgs.callPackage ./packages/metacubexd.nix { };
          sing-box-dashboard = pkgs.callPackage ./packages/sing-box-dashboard.nix { };
        }
      );
    };
}
