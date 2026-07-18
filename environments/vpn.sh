#!/bin/bash
# =============================================================================
# environments/vpn.sh   (ANSSI #8 — dedicated, non-bypassable per-env VPN)
# -----------------------------------------------------------------------------
# For every ENABLED environment with <env>_VPN=1, bring up a HOST-side WireGuard
# tunnel and force that environment's egress THROUGH it — enforced on the host,
# so the guest cannot disable or bypass it ("non débrayable", ANSSI).
#
# How the non-bypass is enforced (all on the host, out of the guest's control):
#   * a WireGuard interface wg<idx> per env (keys/endpoint from config.env);
#   * policy routing: packets from the env's /24 use a table whose default route
#     is the wg interface;
#   * nftables (table inet appliance_vpn, evaluated BEFORE appliance_isol):
#       - DROP env-subnet -> WAN uplink   (can't leak around the tunnel)
#       - ACCEPT env-subnet -> wg<idx>, and masquerade out wg<idx>.
#
# OPT-IN + EXPERIMENTAL: needs a real WireGuard peer (endpoint + keys) and
# on-hardware testing. Default off (no <env>_VPN=1) -> this script is a no-op.
# Run AFTER environments/isolate.sh (it layers on top of the isolation table).
#
# Required per-env config.env vars when <env>_VPN=1:
#   <env>_VPN_PRIVKEY   host private key for this env's tunnel   (SENSITIVE)
#   <env>_VPN_ADDRESS   wg interface address, e.g. 10.9.<idx>.2/32
#   <env>_VPN_PUBKEY    peer (gateway) public key
#   <env>_VPN_ENDPOINT  peer host:port
#   <env>_VPN_ALLOWED   allowed IPs (default 0.0.0.0/0 = full tunnel)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config
require_cmds wg wg-quick ip nft

# Detect WAN (same logic as 05) so we can DROP env->WAN for VPN'd envs.
if [ "${WAN_IFACE:-auto}" = "auto" ]; then
  WAN_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
fi
[ -n "${WAN_IFACE:-}" ] || die "WAN_IFACE unknown; run 05 first or set it in config.env."

mkdir -p /etc/wireguard

any=0
VPN_FWD=""; VPN_NAT=""
for_each_enabled_env | while read -r env idx; do
  [ "$(env_val "$env" VPN 0)" = "1" ] || continue
  any=1
  subnet="$(env_subnet "$env" "$idx")"      # e.g. 10.10.2
  net="${subnet}.0/24"
  wgif="wg${idx}"                           # <=15 chars, unique per env
  priv="$(env_val "$env" VPN_PRIVKEY)"
  addr="$(env_val "$env" VPN_ADDRESS)"
  pub="$(env_val "$env" VPN_PUBKEY)"
  ep="$(env_val "$env" VPN_ENDPOINT)"
  allowed="$(env_val "$env" VPN_ALLOWED 0.0.0.0/0)"
  [ -n "$priv" ] && [ -n "$addr" ] && [ -n "$pub" ] && [ -n "$ep" ] || {
    warn "$env: VPN=1 but missing PRIVKEY/ADDRESS/PUBKEY/ENDPOINT — skipping."; continue; }

  log "$env: WireGuard $wgif -> $ep (egress locked to tunnel) ..."
  # Table=off: we do the policy routing ourselves (per-env table).
  umask 077
  cat > "/etc/wireguard/${wgif}.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $addr
Table = off

[Peer]
PublicKey = $pub
Endpoint = $ep
AllowedIPs = $allowed
PersistentKeepalive = 25
EOF
  umask 022

  wg-quick down "$wgif" 2>/dev/null || true
  wg-quick up "$wgif" || { warn "$env: wg-quick up failed (endpoint/keys?)."; continue; }

  # Policy routing: env subnet -> table (100+idx) whose default is the tunnel.
  rt=$((100 + idx))
  ip route replace default dev "$wgif" table "$rt"
  ip rule del from "$net" lookup "$rt" 2>/dev/null || true
  ip rule add from "$net" lookup "$rt" priority $((1000 + idx))

  VPN_FWD="$VPN_FWD
    ip saddr $net oifname \"$WAN_IFACE\" counter drop
    ip saddr $net oifname \"$wgif\" accept"
  VPN_NAT="$VPN_NAT
    ip saddr $net oifname \"$wgif\" masquerade"
  ok "$env: egress now forced through $wgif; direct WAN dropped."
done

# NOTE: the per-env loop above runs in a pipe subshell, so VPN_FWD/VPN_NAT built
# there don't survive. Rebuild them in the main shell to write the nft table.
VPN_FWD=""; VPN_NAT=""; any=0
for pair in $(for_each_enabled_env | awk '{print $1":"$2}'); do
  env="${pair%:*}"; idx="${pair#*:}"
  [ "$(env_val "$env" VPN 0)" = "1" ] || continue
  [ -f "/etc/wireguard/wg${idx}.conf" ] || continue
  any=1
  net="$(env_subnet "$env" "$idx").0/24"; wgif="wg${idx}"
  VPN_FWD="$VPN_FWD
    ip saddr $net oifname \"$WAN_IFACE\" counter drop
    ip saddr $net oifname \"$wgif\" accept"
  VPN_NAT="$VPN_NAT
    ip saddr $net oifname \"$wgif\" masquerade"
done

if [ "$any" = "0" ]; then
  log "No env has VPN=1 — nothing to do (per-env VPN disabled)."
  exit 0
fi

# nftables table evaluated BEFORE appliance_isol (lower priority number) so the
# 'drop env->WAN' is terminal and the guest cannot leak around the tunnel.
NFT_VPN="/etc/nftables.d/appliance-vpn.nft"
mkdir -p /etc/nftables.d
cat > "$NFT_VPN" <<EOF
#!/usr/sbin/nft -f
table inet appliance_vpn
delete table inet appliance_vpn
table inet appliance_vpn {
  chain forward {
    type filter hook forward priority -2; policy accept;
    ct state established,related accept
$VPN_FWD
  }
  chain postrouting {
    type nat hook postrouting priority 90; policy accept;
$VPN_NAT
  }
}
EOF
MAIN_NFT="/etc/nftables.nft"; [ -f "$MAIN_NFT" ] || MAIN_NFT="/etc/nftables.conf"
if [ -f "$MAIN_NFT" ] && ! grep -q "appliance-vpn.nft" "$MAIN_NFT"; then
  echo "include \"$NFT_VPN\"" >> "$MAIN_NFT"
fi
nft -f "$NFT_VPN"
ok "Per-env VPN egress-lock applied (ANSSI #8: dedicated, non-bypassable tunnel)."

cat <<EOF

Persistence: enable the wg interfaces at boot, e.g. for each VPN'd env idx:
    rc-update add wg-quick default   # or a per-iface init
Verify from inside a VPN'd VM: its public IP should be the VPN endpoint's, and
direct WAN must be blocked (only the tunnel works).
EOF
