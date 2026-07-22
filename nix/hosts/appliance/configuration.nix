# nix/hosts/appliance/configuration.nix
# -----------------------------------------------------------------------------
# The per-machine configuration — the declarative replacement for config.env.
# This is the ONE file an operator edits: the environments and their policies.
# -----------------------------------------------------------------------------
{ ... }:
{
  imports = [ ./hardware.nix ];

  appliance = {
    enable = true;
    subnetBase = "10.10";
    keyboardLayout = "us"; # e.g. "fr:oss"
    wanInterface = "auto";

    # Guest login password lives out-of-store. Provide it via sops-nix/agenix or
    # a first-boot generator; the path below is where the provisioner reads it.
    guest = {
      user = "operator";
      passwordFile = "/run/secrets/guest-password";
    };

    # The environments. index fixes workspace/subnet/bridge and must be stable.
    environments = {
      office = {
        index = 1;
        os = "ubuntu"; # required for Intune/Entra
        desktop = "gnome";
        intune = true;
        msApps = true;
      };
      development = {
        index = 2;
        os = "arch";
        desktop = "gnome";
        # wazuh = true;  # set appliance.wazuhManager before enabling
      };
      administration = {
        index = 3;
        os = "arch";
        desktop = "gnome";
        # Example egress lockdown for the sensitive env (DNS + listed IPs only):
        # egress = { mode = "whitelist"; allow = [ "1.1.1.1" "8.8.8.8" ]; };
      };
    };

    # wazuhManager = "10.0.0.10";  # required if any env sets wazuh = true
  };

  system.stateVersion = "25.05";
}
