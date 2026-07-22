# tests/isolation.nix
# -----------------------------------------------------------------------------
# NixOS VM test for the crown-jewel guarantee: the generated nftables ruleset
# fences every environment from every other. Runs headless in CI — no hardware,
# no nested KVM — the declarative equivalent of isolate.sh's host-side rule
# assertions.
#
# TODO (deeper test): boot the appliance WITH nested guests and reproduce
# isolate.sh's in-guest ping matrix via the qemu-guest-agent. That needs nested
# KVM in the test runner; this lighter check gates the ruleset on every push.
# -----------------------------------------------------------------------------
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "appliance-isolation";

  nodes.machine = { lib, ... }: {
    imports = [ ../nix/modules/appliance ];

    appliance = {
      guest.passwordFile = "/etc/appliance-guest-pw";
      environments = {
        office = { index = 1; os = "ubuntu"; desktop = "none"; };
        development = { index = 2; os = "arch"; desktop = "none"; };
        administration = {
          index = 3;
          os = "arch";
          desktop = "none";
          egress = { mode = "whitelist"; allow = [ "1.1.1.1" ]; };
        };
      };
    };

    # Keep the test hermetic and fast: only the nftables ruleset is under test,
    # so drop the desktop, libvirt and the guest/network provisioners.
    services.xserver.enable = lib.mkForce false;
    services.keyd.enable = lib.mkForce false;
    virtualisation.libvirtd.enable = lib.mkForce false;
    systemd.services.appliance-libvirt-networks.enable = lib.mkForce false;
    systemd.services.appliance-guests.enable = lib.mkForce false;
  };

  testScript = ''
    machine.wait_for_unit("nftables.service")
    machine.succeed("nft list table inet appliance_isol")

    # Every ordered pair of environment subnets is dropped, both directions.
    for a, b in [("1","2"),("1","3"),("2","1"),("2","3"),("3","1"),("3","2")]:
        machine.succeed(
            f"nft list table inet appliance_isol | "
            f"grep -Eq 'ip saddr 10.10.{a}.0/24 ip daddr 10.10.{b}.0/24 .*drop'"
        )

    # Redundant bridge-name drops (survive subnet renumbering).
    machine.succeed(
        "nft list table inet appliance_isol | "
        "grep -Eq 'iifname \"virbr1\" oifname \"virbr2\" .*drop'"
    )

    # Whitelisted env: DNS to its gateway is allowed, the allow-set is allowed,
    # and there is a trailing default-deny for that subnet.
    machine.succeed(
        "nft list table inet appliance_isol | "
        "grep -Eq 'ip saddr 10.10.3.0/24 ip daddr 10.10.3.1 udp dport 53 accept'"
    )
    machine.succeed(
        "nft list table inet appliance_isol | grep -Eq '10.10.3.0/24.*1.1.1.1.*accept'"
    )
    machine.succeed(
        "nft list table inet appliance_isol | "
        "grep -Eq 'ip saddr 10.10.3.0/24 .*drop'"
    )

    # ip forwarding is on (guests reach the internet via routed NAT).
    machine.succeed("test \"$(cat /proc/sys/net/ipv4/ip_forward)\" = 1")
  '';
}
