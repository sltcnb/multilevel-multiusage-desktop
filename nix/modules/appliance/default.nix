# nix/modules/appliance/default.nix
# -----------------------------------------------------------------------------
# The `appliance` NixOS module: top-level options + wiring. Imports the
# feature modules (each maps to one or more scripts from the bash branch) and
# exposes the pure derivation helpers as the `applianceLib` module argument so
# every sub-module derives workspace/subnet/bridge identically.
# -----------------------------------------------------------------------------
{ config, lib, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf mkMerge types;
  cfg = config.appliance;
in
{
  imports = [
    ./environments.nix
    ./host.nix
    ./networking.nix
    ./desktop.nix
    ./guests.nix
  ];

  options.appliance = {
    enable = mkEnableOption "the multilevel isolated-environments appliance" // { default = true; };

    subnetBase = mkOption {
      type = types.str;
      default = "10.10";
      description = "First two octets of the per-env /24s: env with index i uses ${"\${subnetBase}"}.i.0/24.";
    };

    wanInterface = mkOption {
      type = types.str;
      default = "auto";
      example = "enp0s31f6";
      description = ''
        Uplink interface for NAT masquerade. "auto" masquerades traffic leaving
        via any non-bridge interface (robust; no hardcoded NIC name), matching
        the bash branch's default-route detection without an activation-time probe.
      '';
    };

    kioskUser = mkOption {
      type = types.str;
      default = "kiosk";
      description = "Unprivileged autologin desktop user (libvirt/kvm groups, no sudo).";
    };

    keyboardLayout = mkOption {
      type = types.str;
      default = "us";
      example = "fr:oss";
      description = "Host X keyboard layout, optional `:variant` (e.g. fr:oss).";
    };

    trustBar.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Always-visible top bar (reserves a strut) showing the active, colour-coded environment (ANSSI).";
    };

    usbguard.enable = mkOption {
      type = types.bool;
      default = true;
      description = "usbguard default-deny USB policy (HID + hubs allowed).";
    };

    guest.user = mkOption {
      type = types.str;
      default = "operator";
      description = "Login user created inside each guest by cloud-init.";
    };

    wazuhManager = mkOption {
      type = types.str;
      default = "";
      description = "Wazuh manager IP/hostname (required when any env has wazuh = true).";
    };

    hostReserve = {
      ramMB = mkOption { type = types.ints.positive; default = 2048; description = "RAM reserved for the host, never given to VMs."; };
      cores = mkOption { type = types.ints.positive; default = 1; description = "CPU cores reserved for the host."; };
    };
  };

  config = mkMerge [
    # Pure env derivations, available to every appliance sub-module as an arg.
    # Set unconditionally so other modules can consume it during evaluation.
    { _module.args.applianceLib = import ../../lib/environments.nix { inherit lib; }; }

    (mkIf cfg.enable {
      # Top-level assertion: wazuh needs a manager.
      assertions = [{
        assertion = (lib.any (e: e.wazuh) (lib.attrValues cfg.environments)) -> (cfg.wazuhManager != "");
        message = "appliance: an environment enables wazuh but appliance.wazuhManager is empty.";
      }];
    })
  ];
}
