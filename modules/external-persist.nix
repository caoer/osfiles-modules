# modules/external-persist.nix — impermanence with /persist on a SEPARATE,
# host-owned block disk (not a subvolume of the root disk).
#
# Why: the root disk (vda) becomes fully disposable — wiped each boot AND
# re-imageable (golden-clone / OS upgrade) with ZERO identity churn. Host identity
# (ssh host key -> SOPS age recipient, machine-id) and all persistent state live on
# the external disk (vdb, label "persist"), seeded host-side before first boot.
#
# Pairs with a ROOT-ONLY disko layout: ESP + btrfs(@,@nix,@home), btrfs label "nixos",
# and NO @persist subvolume. The @ subvolume is wiped every boot.
#
# Opt-in per host: import this module and set `osf.externalPersist.enable = true`.
#
# Factory form: `{ impermanenceModule }: <nixos-module>`. The flake closes over its
# own impermanence input, so consumers need no impermanence input of their own.
{ impermanenceModule }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.externalPersist;
in
{
  imports = [ impermanenceModule ];

  options.osf.externalPersist = {
    enable = lib.mkEnableOption "impermanence with /persist on a separate host-owned block disk";

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-label/persist";
      description = "Block device backing /persist (a per-VM, host-seeded disk).";
    };

    fsType = lib.mkOption {
      type = lib.types.str;
      default = "ext4";
      description = "Filesystem on the external /persist disk. ext4 by default (only the root disk needs btrfs).";
    };

    staticNetwork = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Treat the host IP as seeded identity: read /persist/etc/net/static.conf
        at boot (ADDRESS/GATEWAY/DNS/IFACE) and render a systemd-networkd unit.
        Falls back to DHCP when the file is absent. Lets a freshly-cloned golden
        come up at its known address with zero per-host config — the IP survives a
        root re-image exactly like the ssh host key. Set false to keep pure DHCP.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # systemd-initrd wipe-root: move the old @ aside and recreate an empty @ subvolume
        # on the root btrfs (label "nixos") every boot. Validated pattern (impermanence-design).
        boot.initrd = {
          systemd.enable = lib.mkDefault true;
          supportedFilesystems = [ "btrfs" ];
          systemd.services.wipe-root = {
            description = "Wipe root subvolume on boot";
            wantedBy = [ "initrd.target" ];
            requires = [ "dev-disk-by\\x2dlabel-nixos.device" ];
            after = [ "dev-disk-by\\x2dlabel-nixos.device" ];
            before = [ "sysroot.mount" ];
            unitConfig.DefaultDependencies = "no";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              mkdir -p /btrfs_tmp
              mount -t btrfs /dev/disk/by-label/nixos /btrfs_tmp

              if [[ -e /btrfs_tmp/@ ]]; then
                  mkdir -p /btrfs_tmp/old_roots
                  timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/@)" "+%Y-%m-%d_%H:%M:%S")
                  mv /btrfs_tmp/@ "/btrfs_tmp/old_roots/$timestamp"
              fi

              delete_subvolume_recursively() {
                  IFS=$'\n'
                  for i in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
                      delete_subvolume_recursively "/btrfs_tmp/$i"
                  done
                  btrfs subvolume delete "$1"
              }

              for i in $(find /btrfs_tmp/old_roots/ -maxdepth 1 -mtime +30); do
                  delete_subvolume_recursively "$i"
              done

              btrfs subvolume create /btrfs_tmp/@
              umount /btrfs_tmp
            '';
          };
        };

        # /persist lives on the EXTERNAL disk. neededForBoot so it is mounted in stage-1,
        # before sops-nix activation (host ssh key -> age recipient) and the persistence
        # bind-mounts. Survives a full root-disk re-image (the disk is never in disko).
        fileSystems."/persist" = {
          inherit (cfg) device;
          inherit (cfg) fsType;
          neededForBoot = true;
        };

        # Base identity + state. Hosts extend via their own
        # environment.persistence."/persist".{directories,files} (NixOS merges these lists).
        # NOTE: persist key FILES individually, never the /etc/ssh directory (hides
        # NixOS-generated sshd_config/moduli). Keys need a trailing newline (OpenSSH 10.3+).
        environment.persistence."/persist" = {
          hideMounts = true;
          directories = [
            "/var/lib/nixos"
            "/var/lib/systemd"
            "/var/db/sudo"
            "/var/log"
            "/root/.ssh"
          ];
          files = [
            "/etc/machine-id"
            "/etc/ssh/ssh_host_ed25519_key"
            "/etc/ssh/ssh_host_ed25519_key.pub"
          ];
        };
      }

      # IP-as-seeded-identity: networkd, static from /persist when seeded, else DHCP.
      (lib.mkIf cfg.staticNetwork {
        networking.useDHCP = lib.mkForce false;

        systemd = {
          network = {
            enable = true;
            # DHCP fallback — used when no static.conf is seeded (bare golden boot).
            # Higher filename number → lower precedence than the 05- static unit.
            networks."20-dhcp" = {
              matchConfig.Name = "en* eth*";
              networkConfig.DHCP = "yes";
            };
          };

          # Render /run/systemd/network/05-persist-static.network from the seeded
          # file BEFORE networkd starts. /persist is neededForBoot (mounted by
          # local-fs.target). Absent/empty file → no-op → DHCP fallback wins.
          services.persist-static-net = {
            description = "Render static network from seeded /persist (IP-as-identity)";
            wantedBy = [ "network-pre.target" ];
            before = [
              "network-pre.target"
              "systemd-networkd.service"
            ];
            after = [ "local-fs.target" ];
            unitConfig.ConditionPathExists = "/persist/etc/net/static.conf";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            path = [ pkgs.coreutils ];
            script = ''
              set -eu
              CONF=/persist/etc/net/static.conf
              # shellcheck source=/dev/null
              . "$CONF"
              [ -n "''${ADDRESS:-}" ] || exit 0
              mkdir -p /run/systemd/network
              {
                echo "[Match]"
                echo "Name=''${IFACE:-en* eth*}"
                echo "[Network]"
                echo "Address=''${ADDRESS}"
                [ -n "''${GATEWAY:-}" ] && echo "Gateway=''${GATEWAY}"
                for d in ''${DNS:-1.1.1.1 8.8.8.8}; do echo "DNS=$d"; done
              } > /run/systemd/network/05-persist-static.network
            '';
          };
        };
      })
    ]
  );
}
