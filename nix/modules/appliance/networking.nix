# nix/modules/appliance/networking.nix
# -----------------------------------------------------------------------------
# The isolation guarantee — declarative equivalent of environments/isolate.sh.
#
#   * one libvirt NAT network per environment (isol-<env> / virbr<idx> /
#     <base>.<idx>.0/24, DHCP on .2-.254), defined by a systemd oneshot;
#   * an `inet appliance_isol` nftables table whose forward chain (priority -1,
#     ahead of libvirt's own rules) drops every ordered pair of environment
#     subnets AND every ordered pair of bridge names (belt-and-suspenders),
#     then applies each env's egress policy; postrouting masquerades outbound.
#
# The all-pairs drops are emitted over ALL defined environments (enabled or
# not), so a disabled-but-still-running guest stays fenced — faithful to
# isolate.sh's use of the full list.
# -----------------------------------------------------------------------------
{ config, lib, pkgs, applianceLib, ... }:
let
  inherit (lib) mkIf concatMapStringsSep concatStringsSep optionalString;
  cfg = config.appliance;

  views = applianceLib.allViews cfg.subnetBase cfg.environments; # all defined
  enabled = builtins.filter (v: v.enable) views;
  bridges = map (v: v.bridge) views;

  # Ordered pairs (a,b) with a != b, over all defined environments.
  pairs = lib.concatMap
    (a: map (b: { inherit a b; }) (builtins.filter (b: b.index != a.index) views))
    views;

  # "auto" WAN = anything leaving via a non-bridge, non-loopback interface. This
  # sidesteps hardcoding the NIC while matching isolate.sh's default-route intent.
  bridgeSet = "{ " + concatStringsSep ", " (map (b: "\"${b}\"") ([ "lo" ] ++ bridges)) + " }";
  wanOut =
    if cfg.wanInterface == "auto"
    then "oifname != ${bridgeSet}"
    else "oifname \"${cfg.wanInterface}\"";

  dropRules = concatMapStringsSep "\n"
    (p: "    ip saddr ${p.a.subnet} ip daddr ${p.b.subnet} counter drop")
    pairs;

  bridgeDrops = concatMapStringsSep "\n"
    (p: "    iifname \"${p.a.bridge}\" oifname \"${p.b.bridge}\" counter drop")
    pairs;

  egressFor = v:
    if v.egress.mode == "all" then
      "    ip saddr ${v.subnet} ${wanOut} accept"
    else
    # whitelist: DNS to the gateway, the allow-set, the VPN iface, then deny.
      concatStringsSep "\n" ([
        "    ip saddr ${v.subnet} ip daddr ${v.hostIP} udp dport 53 accept"
        "    ip saddr ${v.subnet} ip daddr ${v.hostIP} tcp dport 53 accept"
      ]
      ++ lib.optional (v.egress.allow != [ ])
        "    ip saddr ${v.subnet} ${wanOut} ip daddr { ${concatStringsSep ", " v.egress.allow} } accept"
      ++ lib.optional v.vpn.enable
        "    ip saddr ${v.subnet} oifname \"wg${toString v.index}\" accept"
      ++ [ "    ip saddr ${v.subnet} counter drop" ]);

  egressRules = concatMapStringsSep "\n" egressFor enabled;

  masqRules = concatMapStringsSep "\n"
    (v: "    ip saddr ${v.subnet} ${wanOut} masquerade")
    enabled;

  # --- libvirt network XML (NAT + DHCP), one per environment ----------------
  networkXml = v: pkgs.writeText "isol-${v.name}.xml" ''
    <network>
      <name>${v.netName}</name>
      <forward mode='nat'/>
      <bridge name='${v.bridge}' stp='on' delay='0'/>
      <ip address='${v.hostIP}' netmask='255.255.255.0'>
        <dhcp>
          <range start='${v.dhcpStart}' end='${v.dhcpEnd}'/>
        </dhcp>
      </ip>
    </network>
  '';

  virsh = "${pkgs.libvirt}/bin/virsh";

  defineNetworks = pkgs.writeShellScript "appliance-define-networks" ''
    set -euo pipefail
    # Tear down the shared "default" NAT net (cross-env leakage risk).
    ${virsh} net-destroy default 2>/dev/null || true
    ${virsh} net-autostart --disable default 2>/dev/null || true
    ${virsh} net-undefine default 2>/dev/null || true

    ${concatMapStringsSep "\n" (v: ''
      ${virsh} net-info ${v.netName} >/dev/null 2>&1 || ${virsh} net-define ${networkXml v}
      ${virsh} net-start ${v.netName} 2>/dev/null || true
      ${virsh} net-autostart ${v.netName}
    '') enabled}
  '';
in
{
  config = mkIf cfg.enable {
    # Guests reach the internet via routed NAT.
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # --- The isolation table -------------------------------------------------
    networking.nftables.enable = true;
    networking.nftables.tables.appliance_isol = {
      family = "inet";
      content = ''
        chain forward {
          # priority -1 => evaluated just BEFORE libvirt's own forward rules,
          # so a cross-env drop wins no matter what libvirt allows.
          type filter hook forward priority -1; policy accept;
          ct state established,related accept

          # --- all-pairs subnet drop ---
        ${dropRules}

          # --- all-pairs bridge-name drop (redundant, survives renumbering) ---
        ${bridgeDrops}

          # --- per-environment egress policy ---
        ${egressRules}
        }

        chain postrouting {
          type nat hook postrouting priority 100; policy accept;
        ${masqRules}
        }
      '';
    };

    # --- Declarative libvirt networks ---------------------------------------
    systemd.services.appliance-libvirt-networks = {
      description = "Define per-environment isolated libvirt networks";
      after = [ "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${defineNetworks}";
      };
    };
  };
}
