# nix/modules/appliance/environments.nix
# -----------------------------------------------------------------------------
# The typed environment model — the declarative replacement for $ENVS + the
# `${env}_*` shell-convention variables in the bash branch's config.env.
#
# This is the crown jewel of the port: what used to be string parsing in POSIX
# sh becomes a first-class NixOS option with types, defaults and assertions.
# The DERIVATIONS (workspace/subnet/bridge/…) live in nix/lib/environments.nix
# and are consumed by the networking / desktop / guests modules via the
# `applianceLib` module argument.
# -----------------------------------------------------------------------------
{ config, lib, applianceLib, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.appliance;

  # Per-environment submodule. `name` is the attribute key (office, …).
  envType = types.submodule ({ name, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Create and show this environment.";
      };

      index = mkOption {
        type = types.ints.positive;
        description = ''
          1-based position that fixes this environment's workspace number,
          /24 subnet third octet and bridge (virbr<index>). Assign it once and
          never change it: enabling/disabling other environments must not
          renumber this one (ANSSI stability requirement).
        '';
      };

      os = mkOption {
        type = types.enum [ "ubuntu" "arch" "debian" ];
        default = "ubuntu";
        description = ''
          Guest OS, provisioned via cloud-init. The office/desktop environment
          MUST be ubuntu (Intune/Entra enrollment is Ubuntu-only).
        '';
      };

      desktop = mkOption {
        type = types.enum [ "gnome" "xfce4" "kde" "mate" "lxqt" "none" ];
        default = "gnome";
        description = "Guest desktop environment (installed in-guest by cloud-init). \"none\" = CLI only.";
      };

      color = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "#c62828";
        description = "Trust-bar colour for this environment. null = pick from the default palette by index.";
      };

      egress = {
        mode = mkOption {
          type = types.enum [ "all" "whitelist" ];
          default = "all";
          description = "Outbound policy: full NAT (`all`) or DNS + `allow` list only (`whitelist`).";
        };
        allow = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "1.1.1.1" "8.8.8.8" "10.0.0.0/8" ];
          description = "IPs/CIDRs permitted when `mode = \"whitelist\"` (DNS to the gateway is always allowed).";
        };
      };

      intune = mkEnableOption "Microsoft Intune/Entra enrollment prep (Ubuntu only)";
      msApps = mkEnableOption "Outlook + Teams as Edge PWAs";
      wazuh = mkEnableOption "the Wazuh agent (requires appliance.wazuhManager)";

      vpn = {
        enable = mkEnableOption "a dedicated, host-enforced, non-bypassable WireGuard tunnel";
        privateKeyFile = mkOption {
          type = types.nullOr types.str; # str: an out-of-store path, never copied to the Nix store
          default = null;
          description = "Absolute path to the host WireGuard private key (out-of-store; e.g. sops-nix/agenix).";
        };
        address = mkOption { type = types.str; default = ""; example = "10.9.2.2/32"; description = "Tunnel address."; };
        peerPublicKey = mkOption { type = types.str; default = ""; description = "Peer/gateway public key."; };
        endpoint = mkOption { type = types.str; default = ""; example = "vpn.example.com:51820"; description = "Peer endpoint."; };
        allowedIPs = mkOption { type = types.listOf types.str; default = [ "0.0.0.0/0" ]; description = "AllowedIPs (default = full tunnel)."; };
      };

      encryptDisk = mkEnableOption "per-VM LUKS-encrypted qcow2";
      diskPassFile = mkOption {
        type = types.nullOr types.str; # str: an out-of-store path, never copied to the Nix store
        default = null;
        description = "Absolute path (out-of-store) to the per-VM LUKS passphrase when encryptDisk = true.";
      };

      # null = auto-split evenly across enabled envs at first boot (host headroom
      # reserved first) — see guests.nix. Set to override for a fixed allocation.
      memoryMB = mkOption { type = types.nullOr types.ints.positive; default = null; description = "Guest RAM (MB). null = auto-split."; };
      vcpus = mkOption { type = types.nullOr types.ints.positive; default = null; description = "Guest vCPUs. null = auto-split."; };
      diskGB = mkOption { type = types.nullOr types.ints.positive; default = null; description = "Guest max virtual disk (GB). null = auto-split."; };
    };
  });
in
{
  options.appliance.environments = mkOption {
    type = types.attrsOf envType;
    default = { };
    description = "The isolated environments (KVM guests) this appliance runs.";
  };

  config = {
    # --- Structural invariants of the environment model --------------------
    assertions =
      let
        views = applianceLib.allViews cfg.subnetBase cfg.environments;
        indices = map (v: v.index) views;
      in
      [
        {
          assertion = (builtins.length indices) == (builtins.length (lib.unique indices));
          message = "appliance.environments: index must be unique per environment; got indices ${toString indices}.";
        }
      ]
      # office/desktop must be Ubuntu when Intune is on (Entra is Ubuntu-only).
      ++ (map
        (v: {
          assertion = v.intune -> (v.os == "ubuntu");
          message = "appliance.environments.${v.name}: intune requires os = \"ubuntu\".";
        })
        views)
      # A VPN environment needs the WireGuard essentials.
      ++ (map
        (v: {
          assertion = v.vpn.enable ->
            (v.vpn.privateKeyFile != null && v.vpn.peerPublicKey != "" && v.vpn.endpoint != "");
          message = "appliance.environments.${v.name}: vpn.enable requires privateKeyFile, peerPublicKey and endpoint.";
        })
        views);
  };
}
