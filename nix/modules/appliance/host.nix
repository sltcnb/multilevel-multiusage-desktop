# nix/modules/appliance/host.nix
# -----------------------------------------------------------------------------
# The socle (host TCB). Declarative equivalent of:
#   host/detect-and-install.sh  -> libvirtd, KVM, nested virt, packages
#   host/configure.sh (user)    -> unprivileged kiosk user in libvirt/kvm
#   host/harden.sh (sysctl)     -> kernel hardening
# Networking isolation, the desktop and the guests live in their own modules.
# -----------------------------------------------------------------------------
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkIf;
  cfg = config.appliance;
in
{
  config = mkIf cfg.enable {
    # mkOptionDefault (not mkDefault): the NixOS test framework sets the hostname
    # at mkDefault, so a plain mkDefault here would tie and conflict. This still
    # applies for the real appliance and yields to any explicit hostName.
    networking.hostName = lib.mkOptionDefault "appliance";

    # --- Virtualisation host --------------------------------------------------
    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = false; # qemu drops to an unprivileged user
        swtpm.enable = true; # needed later for measured-boot / vTPM guests
        ovmf.enable = true; # UEFI guests
      };
      # The bash branch destroys the shared libvirt "default" NAT network for
      # isolation; we never define it (onBoot only starts what we declare).
      onBoot = "ignore";
      onShutdown = "shutdown";
    };
    # SPICE USB redirection helper (used later for YubiKey -> VM routing).
    virtualisation.spiceUSBRedirection.enable = true;

    # Nested virtualisation for both vendors; the matching module is loaded by
    # hardware-configuration.nix, the other line is inert.
    boot.extraModprobeConfig = ''
      options kvm_intel nested=1
      options kvm_amd nested=1
    '';

    # --- Users ----------------------------------------------------------------
    # Unprivileged autologin desktop user: can view/launch VMs, no sudo, no root.
    # Password stays locked; getty --autologin (desktop.nix) bypasses auth, so a
    # compromise of the desktop session still cannot escalate on the host.
    users.users.${cfg.kioskUser} = {
      isNormalUser = true;
      description = "Kiosk (unprivileged VM viewer)";
      extraGroups = [ "libvirtd" "kvm" "video" "input" ];
    };
    # No sudo on the host at all — root admin is done on tty2 (Ctrl+Alt+F2).
    security.sudo.enable = lib.mkDefault false;
    # root's password is set out-of-band (sops-nix/agenix or first boot); the
    # shipped image should ship it locked. Declared here as a reminder.
    # users.users.root.hashedPasswordFile = config.sops.secrets.root-password.path;

    # --- Base packages (host is deliberately tiny) ---------------------------
    environment.systemPackages = with pkgs; [
      virt-viewer # the SPICE client i3 launches per environment
      spice-gtk
      nftables
      jq # trust-bar active-env script + isolation checks
    ];

    # --- Kernel / sysctl hardening (subset of host/harden.sh) ----------------
    boot.kernel.sysctl = {
      "kernel.kptr_restrict" = 2;
      "kernel.dmesg_restrict" = 1;
      "kernel.unprivileged_bpf_disabled" = 1;
      "net.core.bpf_jit_harden" = 2;
      "kernel.yama.ptrace_scope" = 1;
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      # ip_forward is enabled by the networking module (guests need routed NAT).
    };
    # Opt-in stronger hardening lives behind the upstream profile; enable in the
    # host config once validated on hardware:
    #   imports = [ "${modulesPath}/profiles/hardened.nix" ];

    # --- Nix -----------------------------------------------------------------
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    # Atomic upgrade + rollback is a core reason for the port: keep a few
    # generations in the bootloader menu.
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;

    console.keyMap = lib.mkDefault (lib.head (lib.splitString ":" cfg.keyboardLayout));
    time.timeZone = lib.mkDefault "Europe/Paris";
  };
}
