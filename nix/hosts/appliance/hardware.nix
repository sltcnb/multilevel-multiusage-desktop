# nix/hosts/appliance/hardware.nix
# -----------------------------------------------------------------------------
# PLACEHOLDER hardware profile so the flake evaluates and the image builds.
# On real hardware, REPLACE this with the output of `nixos-generate-config`
# (or nixos-facter). Everything here is mkDefault, so the nixos-generators
# image formats (raw-efi / install-iso) override it cleanly at build time.
# -----------------------------------------------------------------------------
{ lib, ... }:
{
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

  boot.initrd.availableKernelModules = lib.mkDefault [
    "xhci_pci" "ahci" "nvme" "usbhid" "sd_mod" "virtio_blk" "virtio_pci"
  ];
  # Loaded on the real machine by the generated config; harmless here.
  boot.kernelModules = lib.mkDefault [ "kvm-intel" "kvm-amd" ];

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
