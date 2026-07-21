#!/bin/bash
# =============================================================================
# environments/isolate.sh
# -----------------------------------------------------------------------------
# The critical isolation layer. Defense-in-depth:
#   1. Per-VM isolated libvirt networks (separate bridge + /24 each). Ensured
#      here authoritatively (03 also ensures them; this repairs/confirms).
#   2. Explicit host nftables rules that DROP all traffic BETWEEN the VM bridges
#      /subnets, while ALLOWING each VM outbound to the internet via NAT.
#   3. Verification test: from each VM, ping the other two (must FAIL) and ping
#      the internet (must SUCCEED). Prints pass/fail.
#
# Layering: libvirt's own per-network firewalling + our explicit cross-bridge
# DROP means even if one layer is misconfigured, the other still blocks peers.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config
require_cmds nft virsh

# -----------------------------------------------------------------------------
# 1. Auto-detect WAN uplink interface (the one with the default route).
# -----------------------------------------------------------------------------
if [ "${WAN_IFACE:-auto}" = "auto" ]; then
  WAN_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  [ -n "$WAN_IFACE" ] || die "Could not auto-detect WAN interface; set WAN_IFACE in config.env."
fi
set_kv WAN_IFACE "$WAN_IFACE"
log "WAN uplink: $WAN_IFACE"

# -----------------------------------------------------------------------------
# 2. Ensure the three isolated networks exist (idempotent, same as 03).
# -----------------------------------------------------------------------------
ensure_net() {
  name="$1"; bridge="$2"; subnet="$3"
  if ! virsh net-info "$name" >/dev/null 2>&1; then
    tmpxml="$(mktemp)"
    cat > "$tmpxml" <<EOF
<network>
  <name>$name</name>
  <forward mode='nat'/>
  <bridge name='$bridge' stp='on' delay='0'/>
  <ip address='${subnet}.1' netmask='255.255.255.0'>
    <dhcp><range start='${subnet}.2' end='${subnet}.254'/></dhcp>
  </ip>
</network>
EOF
    virsh net-define "$tmpxml"; rm -f "$tmpxml"
  fi
  virsh net-start "$name" 2>/dev/null || true
  virsh net-autostart "$name" 2>/dev/null || true
}
# Ensure an isolated network per ENABLED env, and collect "env:idx" tokens.
LIST=""
for_each_enabled_env | while read -r env idx; do
  ensure_net "$(env_net "$env")" "$(env_bridge "$env" "$idx")" "$(env_subnet "$env" "$idx")"
done
LIST="$(for_each_enabled_env | awk '{print $1":"$2}')"

# Guard (fail closed): a non-empty EGRESS_ALLOW only has effect in whitelist mode.
# If an env sets an allow-list but leaves MODE=all, emit_egress ignores it and
# emits an unconditional WAN accept — egress is wide open while the config looks
# locked down. Refuse rather than mislead.
for a in $LIST; do
  ea="${a%:*}"
  if [ "$(env_val "$ea" EGRESS_MODE all)" != "whitelist" ] && [ -n "$(env_val "$ea" EGRESS_ALLOW)" ]; then
    die "$ea: EGRESS_ALLOW is set but EGRESS_MODE is not 'whitelist' — the allow-list would be IGNORED and egress left wide open. Set ${ea}_EGRESS_MODE=whitelist (or clear ${ea}_EGRESS_ALLOW)."
  fi
done

# emit_egress <subnet-net> <gw-ip> <mode> <allow-list> -> nft forward lines.
emit_egress() {
  net="$1"; gw="$2"; mode="$3"; allow="$4"; idx="$5"
  if [ "$mode" = "whitelist" ]; then
    printf '    ip saddr %s ip daddr %s udp dport 53 accept\n' "$net" "$gw"
    printf '    ip saddr %s ip daddr %s tcp dport 53 accept\n' "$net" "$gw"
    if [ -n "$allow" ]; then
      set_str="$(echo "$allow" | tr ' ' ',')"
      printf '    ip saddr %s oifname "%s" ip daddr { %s } accept\n' "$net" "$WAN_IFACE" "$set_str"
    fi
    # If this env is VPN-locked (environments/vpn.sh brings up wg<idx>), let its
    # tunnel-bound traffic through here too. Base chains on the same hook are ALL
    # evaluated and an accept in appliance_vpn is not terminal for appliance_isol,
    # so without this the whitelist drop below would kill packets vpn.sh accepted,
    # leaving a VPN+whitelist env with zero connectivity. Harmless when no wg<idx>
    # exists (the oifname simply never matches).
    printf '    ip saddr %s oifname "wg%s" accept\n' "$net" "$idx"
    printf '    ip saddr %s counter drop\n' "$net"
  else
    printf '    ip saddr %s oifname "%s" accept\n' "$net" "$WAN_IFACE"
  fi
}

# Build nftables rule fragments by iterating enabled envs (all-pairs DROP).
DROP_RULES=""; BRIDGE_DROP=""; EGRESS_RULES=""; NAT_RULES=""
for a in $LIST; do
  ea="${a%:*}"; ia="${a#*:}"; na="$(env_subnet "$ea" "$ia").0/24"; ba="$(env_bridge "$ea" "$ia")"; gwa="$(env_subnet "$ea" "$ia").1"
  for b in $LIST; do
    [ "$a" = "$b" ] && continue
    eb="${b%:*}"; ib="${b#*:}"; nb="$(env_subnet "$eb" "$ib").0/24"; bb="$(env_bridge "$eb" "$ib")"
    DROP_RULES="$DROP_RULES
    ip saddr $na ip daddr $nb counter drop"
    BRIDGE_DROP="$BRIDGE_DROP
    iifname \"$ba\" oifname \"$bb\" counter drop"
  done
  EGRESS_RULES="$EGRESS_RULES
$(emit_egress "$na" "$gwa" "$(env_val "$ea" EGRESS_MODE all)" "$(env_val "$ea" EGRESS_ALLOW)" "$ia")"
  NAT_RULES="$NAT_RULES
    ip saddr $na oifname \"$WAN_IFACE\" masquerade"
done
log "Isolation for envs: $(echo "$LIST" | tr '\n' ' ')"

# -----------------------------------------------------------------------------
# 3. nftables: block ALL inter-env traffic; permit each env's outbound per policy.
# -----------------------------------------------------------------------------
log "Applying nftables inter-env DROP + NAT rules ..."
NFT_FILE="/etc/nftables.d/appliance-isolation.nft"
mkdir -p /etc/nftables.d

cat > "$NFT_FILE" <<EOF
#!/usr/sbin/nft -f
# ===== Appliance VM isolation (generated by environments/isolate.sh) =====
table inet appliance_isol
delete table inet appliance_isol

table inet appliance_isol {
  chain forward {
    type filter hook forward priority -1; policy accept;
    ct state established,related accept

    # HARD BLOCK: every enabled-env subnet -> every OTHER env subnet (both dirs).
$DROP_RULES

    # Belt-and-suspenders: same block by bridge interface name.
$BRIDGE_DROP

    # Per-env egress policy ("all" = full internet, "whitelist" = DNS + listed).
$EGRESS_RULES
  }

  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
$NAT_RULES
  }
}
EOF

# Ensure the main nftables config includes our drop-in (Alpine + Debian).
MAIN_NFT="/etc/nftables.nft"
[ -f "$MAIN_NFT" ] || MAIN_NFT="/etc/nftables.conf"
if [ -f "$MAIN_NFT" ] && ! grep -q "appliance-isolation.nft" "$MAIN_NFT"; then
  echo "include \"$NFT_FILE\"" >> "$MAIN_NFT"
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-appliance-forward.conf
nft -f "$NFT_FILE"
ok "nftables isolation applied."

# -----------------------------------------------------------------------------
# 3b. HOST-SIDE assertion (no guest agent needed): every ordered env pair has a
#     live DROP rule.
# -----------------------------------------------------------------------------
log "Host-side check: verifying inter-env DROP rules are live ..."
live="$(nft list table inet appliance_isol 2>/dev/null || true)"; miss=0; npair=0
for a in $LIST; do
  ea="${a%:*}"; ia="${a#*:}"; na="$(env_subnet "$ea" "$ia").0/24"
  for b in $LIST; do
    [ "$a" = "$b" ] && continue
    eb="${b%:*}"; ib="${b#*:}"; nb="$(env_subnet "$eb" "$ib").0/24"; npair=$((npair+1))
    if echo "$live" | grep -q "ip saddr $na ip daddr $nb .*drop"; then
      ok   "DROP present: $ea -> $eb"
    else
      warn "DROP MISSING: $ea -> $eb"; miss=$((miss+1))
    fi
  done
done
[ "$miss" -eq 0 ] && ok "All $npair inter-env DROP rules present." || warn "$miss/$npair DROP rule(s) missing — isolation NOT complete!"

# -----------------------------------------------------------------------------
# 4. Verification test.
#    For each VM: run commands inside the guest via the qemu-guest-agent
#    (installed by cloud-init in 03). Ping the other two VM gateways/hosts
#    (must FAIL) and ping the internet (must SUCCEED). Prints PASS/FAIL.
#
#    We ping each peer's GATEWAY .1 AND a would-be peer host .2 — both must fail.
#    If the guest agent isn't up yet, we note SKIPPED (re-run after boot).
# -----------------------------------------------------------------------------
guest_exec() {
  # guest_exec <domain> <command...> -> prints exit code of in-guest command.
  dom="$1"; shift
  out="$(virsh -q qemu-agent-command "$dom" \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$*\"],\"capture-output\":true}}" \
    2>/dev/null)" || { echo "AGENT_DOWN"; return; }
  pid="$(echo "$out" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')"
  [ -n "$pid" ] || { echo "AGENT_DOWN"; return; }
  sleep 3
  st="$(virsh -q qemu-agent-command "$dom" \
    "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>/dev/null)"
  echo "$st" | sed -n 's/.*"exitcode":\([0-9]*\).*/\1/p'
}

# report expected(0=success,1=fail) actual label
verify() {
  dom="$1"; expect="$2"; label="$3"; cmd="$4"
  rc="$(guest_exec "$dom" "$cmd")"
  if [ "$rc" = "AGENT_DOWN" ] || [ -z "$rc" ]; then
    warn "[$dom] $label -> SKIPPED (guest agent not ready)"
    return
  fi
  # normalize: rc 0 = command succeeded (reachable); non-zero = unreachable.
  reached=$([ "$rc" = "0" ] && echo yes || echo no)
  if [ "$expect" = "reach" ] && [ "$reached" = "yes" ]; then
    ok   "[$dom] $label -> PASS (reachable, expected)"
  elif [ "$expect" = "block" ] && [ "$reached" = "no" ]; then
    ok   "[$dom] $label -> PASS (blocked, expected)"
  else
    warn "[$dom] $label -> FAIL (reached=$reached, expected=$expect)"
  fi
}

PING='ping -c1 -W2'
log "Running isolation verification (guests must be booted with guest agent) ..."

# For each enabled env: must NOT reach any OTHER enabled env's gateway; MUST
# reach the internet (unless its egress is whitelisted without 1.1.1.1).
for a in $LIST; do
  ea="${a%:*}"
  for b in $LIST; do
    [ "$a" = "$b" ] && continue
    eb="${b%:*}"; ib="${b#*:}"; gw="$(env_subnet "$eb" "$ib").1"
    verify "$ea" block "cannot reach $eb net" "$PING $gw"
  done
  if [ "$(env_val "$ea" EGRESS_MODE all)" = "all" ]; then
    verify "$ea" reach "reaches internet (1.1.1.1)" "$PING 1.1.1.1"
  fi
done

cat <<EOF

Isolation verification complete. Any FAIL = investigate (see README).
If SKIPPED: wait for guests to finish cloud-init, then re-run:  ./environments/isolate.sh
EOF
