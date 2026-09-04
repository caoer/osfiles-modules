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
    # Pin a stable release tag (upstream also tags -beta.N — skip those) —
    # floating `main` shipped 0.3.0 without node-pty prebuilds (terminal
    # worker crash). Wrapper in packages/paseo.nix asserts/injects pty.node
    # so a future tracer regression fails the build; bump its npmDepsHash
    # alongside this url on every version bump.
    paseo = {
      url = "github:getpaseo/paseo/v0.7.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # THE central herdr pin for the whole fleet (agent terminal multiplexer),
    # paired with modules/herdr — one binary AND one config.toml everywhere.
    # Our fork: upstream release + the `[remote].ssh_command` knob the mac's
    # herdr-eternal client needs, built by the fork's Woodpecker pipeline and
    # served from cache.0xtau.com. Deliberately NO `inputs.nixpkgs.follows`:
    # the cached closure is keyed on the fork's own lock, and a follows here
    # means every host compiles Rust + zig again. osfiles pins the same URL;
    # keep both locks on one rev or `herdr --remote` re-bootstraps on a
    # version mismatch. To bump: rebase the fork's main on the new upstream
    # tag, push, `nix flake update herdr` here and in osfiles.
    herdr.url = "git+https://git.0xdao.app/caoer115/herdr?ref=main&shallow=1";

    # herdr-eternal — resumable transport for `herdr --remote` (WebSocket,
    # byte-exact resume across sleep and roaming). Member nodes run its server
    # via nixosModules.herdr-eternal; the mac's client lives in osfiles.
    herdr-eternal = {
      url = "github:Mic92/herdr-eternal";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

        # herdr-eternal-server for `herdr --remote` (osf.herdrEternal.*).
        herdr-eternal = import ./modules/herdr-eternal/herdr-eternal.nixos.nix {
          herdrEternalFlake = inputs.herdr-eternal;
          herdrFlake = inputs.herdr;
        };

        # Default: member-base + agent NixOS modules (ucc, paseo, herdr-eternal).
        default = import ./modules/_all-nixos.nix {
          paseoFlake = paseo;
          tmuxSrc = inputs.tmux-src;
          herdrEternalFlake = inputs.herdr-eternal;
          herdrFlake = inputs.herdr;
        };
      };

      # Foreign (non-NixOS, system-manager) modules.
      systemManagerModules = {
        default = import ./modules/_all-sm.nix { paseoFlake = paseo; };
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
          # herdr-eternal server + client, re-exported from upstream.
          herdr-eternal = inputs.herdr-eternal.packages.${system}.default;
        }
        // nixpkgs.lib.optionalAttrs (inputs.hunk.packages ? ${system}) {
          # hunk — central fleet pin, re-exported straight from upstream (no
          # wrapper). Consumers put it in home.packages the way they do paseo:
          #   inputs.osf-modules.packages.${pkgs.stdenv.hostPlatform.system}.hunk
          # Guard is upstream's system set, not ours — see the input comment.
          hunk = inputs.hunk.packages.${system}.default;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          codex = pkgs.callPackage ./packages/codex.nix { };
          metacubexd = pkgs.callPackage ./packages/metacubexd.nix { };
          watchdog = pkgs.callPackage ./packages/watchdog.nix { };
        }
      );
    };
}
