# modules/hardware.nix — UEFI + systemd-boot for a Proxmox VM (OVMF).
# systemd-boot installs the removable /EFI/BOOT/BOOTX64.EFI fallback, so OVMF boots a
# freshly-imported image with empty NVMRAM (unlike a stock Debian cloud image).
#
# Factory form: `{ diskoModule }: <nixos-module>`. The flake closes over its own
# disko input, so consumers need no disko input of their own.
{ diskoModule }:
{ modulesPath, ... }:
{
  imports = [
    diskoModule
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };
    # Clone-and-grow: the template image is built at 8G; a clone's root disk is
    # resized up (e.g. 200G) on the Proxmox host. Grow the last partition to fill
    # the disk at boot; the btrfs root grows via x-systemd.growfs (see disko.nix).
    growPartition = true;
    kernelParams = [
      "console=tty0"
      "console=ttyS0,115200n8"
      "net.ifnames=0"
    ];
    initrd.availableKernelModules = [
      "virtio_scsi"
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "sd_mod"
      "sr_mod"
      "btrfs"
    ];
    supportedFilesystems = [ "btrfs" ];
  };
}
