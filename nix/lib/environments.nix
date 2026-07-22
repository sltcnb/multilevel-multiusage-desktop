# nix/lib/environments.nix
# -----------------------------------------------------------------------------
# Pure derivations for the environment model — the Nix equivalent of the
# env_* helpers in the bash branch's lib/common.sh.
#
# Each environment's INDEX (1-based, explicit) fixes its workspace number, /24
# subnet and bridge, so enabling/disabling one never renumbers the others.
# Everything here is a pure function of (subnetBase, name, per-env config); no
# module system, no I/O — trivially testable.
# -----------------------------------------------------------------------------
{ lib }:
let
  inherit (lib) mapAttrsToList sort mod elemAt;

  # Default trust-bar palette, indexed by (index - 1). ANSSI wants each
  # environment visually unmistakable; overridable per-env via `color`.
  palette = [
    "#2e7d32" # green  — office / everyday
    "#1565c0" # blue   — development
    "#c62828" # red    — administration / sensitive
    "#6a1b9a" # purple
    "#ef6c00" # orange
    "#00838f" # teal
  ];
in
rec {
  netName = name: "isol-${name}"; # libvirt network name
  bridge = index: "virbr${toString index}"; # bridge iface (<=15 chars)
  subnetPrefix = subnetBase: index: "${subnetBase}.${toString index}"; # e.g. 10.10.1
  subnetCidr = subnetBase: index: "${subnetPrefix subnetBase index}.0/24";
  hostIP = subnetBase: index: "${subnetPrefix subnetBase index}.1";
  dhcpStart = subnetBase: index: "${subnetPrefix subnetBase index}.2";
  dhcpEnd = subnetBase: index: "${subnetPrefix subnetBase index}.254";

  colorFor = index: color:
    if color != null then color
    else elemAt palette (mod (index - 1) (builtins.length palette));

  # A "view" = the raw per-env config enriched with derived, stable attributes.
  # Consuming modules (networking, desktop, guests) work off views, never the
  # raw submodule, so the derivation logic lives in exactly one place.
  mkView = subnetBase: name: cfg: {
    inherit name;
    inherit (cfg)
      enable index os desktop egress intune msApps wazuh vpn
      encryptDisk memoryMB vcpus diskGB;
    netName = netName name;
    bridge = bridge cfg.index;
    subnetPrefix = subnetPrefix subnetBase cfg.index;
    subnet = subnetCidr subnetBase cfg.index;
    hostIP = hostIP subnetBase cfg.index;
    dhcpStart = dhcpStart subnetBase cfg.index;
    dhcpEnd = dhcpEnd subnetBase cfg.index;
    workspace = cfg.index; # workspace number == index, by design
    title = lib.toUpper name; # OFFICE / DEVELOPMENT / ...
    color = colorFor cfg.index cfg.color;
    # apt-based (ubuntu/debian) vs arch — drives cloud-init package steps.
    osFamily = if cfg.os == "arch" then "arch" else "apt";
  };

  # All environments as views, sorted by index for stable ordering (attrset
  # key order is alphabetical in Nix, so we sort explicitly on index).
  allViews = subnetBase: environments:
    sort (a: b: a.index < b.index)
      (mapAttrsToList (name: cfg: mkView subnetBase name cfg) environments);

  enabledViews = subnetBase: environments:
    builtins.filter (v: v.enable) (allViews subnetBase environments);
}
