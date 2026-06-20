# modules/disko.nix — ROOT-ONLY layout for the external-/persist pattern.
# ESP + btrfs(@,@nix,@home), label "nixos". NO @persist subvolume — /persist lives on
# a separate host-owned disk (see external-persist.nix). The @ subvolume
# is wiped every boot by the initrd wipe-root unit.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    # Build-time image size for system.build.diskoImages (the full osfiles closure
    # exceeds the 2G default). The real VM root disk is resized post-clone.
    imageSize = "8G";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          name = "ESP";
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [
              "-L"
              "nixos"
              "-f"
            ];
            subvolumes = {
              "@" = {
                mountpoint = "/";
                mountOptions = [
                  "subvol=@"
                  "compress=zstd:3"
                  "noatime"
                  # Grow btrfs to fill the (post-clone resized) partition on boot.
                  "x-systemd.growfs"
                ];
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [
                  "subvol=@nix"
                  "compress=zstd:3"
                  "noatime"
                ];
              };
              "@home" = {
                mountpoint = "/home";
                mountOptions = [
                  "subvol=@home"
                  "compress=zstd:3"
                  "noatime"
                ];
              };
            };
          };
        };
      };
    };
  };
}
