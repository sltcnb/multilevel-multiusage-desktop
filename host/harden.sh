#!/bin/bash
# =============================================================================
# host/harden.sh   (ANSSI #2 — socle durci à l'état de l'art)
# -----------------------------------------------------------------------------
# Hardens the host ("socle"): kernel sysctl hardening (always) + an optional
# default-DROP host INPUT firewall (nothing should connect TO the socle). This
# is defense for the base system itself; VM isolation is handled by 05.
#
# Runs at first boot (idempotent). Safe defaults: sysctls always applied; the
# host-input firewall is OPT-IN (HARDEN_INPUT=1) so it can't lock out an SSH you
# rely on during setup.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config

# -----------------------------------------------------------------------------
# 1. Kernel / network sysctl hardening (ANSSI état-de-l'art baseline).
# -----------------------------------------------------------------------------
log "Applying kernel sysctl hardening ..."
cat > /etc/sysctl.d/90-appliance-hardening.conf <<'EOF'
# --- kernel info leaks / attack surface ---
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.yama.ptrace_scope=1
kernel.kexec_load_disabled=1
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.perf_event_paranoid=3
kernel.randomize_va_space=2
fs.suid_dumpable=0
# --- filesystem link/fifo protections ---
fs.protected_symlinks=1
fs.protected_hardlinks=1
fs.protected_fifos=2
fs.protected_regular=2
# --- network anti-spoofing / no redirects / no source routing ---
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.log_martians=1
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_source_route=0
EOF
# Apply now (ignore keys the running kernel lacks).
sysctl -p /etc/sysctl.d/90-appliance-hardening.conf 2>/dev/null || \
  while read -r line; do case "$line" in ''|\#*) continue;; esac; sysctl -w "$line" 2>/dev/null || true; done < /etc/sysctl.d/90-appliance-hardening.conf
ok "sysctl hardening applied."

# Disable core dumps (no sensitive memory to disk).
echo '* hard core 0' > /etc/security/limits.d/00-appliance-nocore.conf 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. Host INPUT firewall (OPT-IN via HARDEN_INPUT=1). Default-DROP everything TO
#    the host except loopback, established/related, ICMP, and DHCP client. The
#    socle exposes no services. Set HOST_SSH=1 to keep sshd reachable (port 22).
# -----------------------------------------------------------------------------
if [ "${HARDEN_INPUT:-0}" = "1" ]; then
  log "Applying default-DROP host INPUT firewall ..."
  ssh_rule=""
  [ "${HOST_SSH:-0}" = "1" ] && ssh_rule='    tcp dport 22 accept'
  cat > /etc/nftables.d/appliance-host-input.nft <<EOF
#!/usr/sbin/nft -f
table inet appliance_host_input
delete table inet appliance_host_input
table inet appliance_host_input {
  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
    udp sport 67 udp dport 68 accept    # DHCP client replies
$ssh_rule
    # Guests reach the host only as their gateway (DNS/DHCP on the virbr* nets);
    # those arrive on the bridge ifaces which libvirt already permits.
  }
}
EOF
  MAIN_NFT="/etc/nftables.nft"; [ -f "$MAIN_NFT" ] || MAIN_NFT="/etc/nftables.conf"
  if [ -f "$MAIN_NFT" ] && ! grep -q "appliance-host-input.nft" "$MAIN_NFT"; then
    echo "include \"/etc/nftables.d/appliance-host-input.nft\"" >> "$MAIN_NFT"
  fi
  nft -f /etc/nftables.d/appliance-host-input.nft && ok "Host INPUT firewall applied (default-drop)."
else
  log "HARDEN_INPUT=0 — host INPUT firewall not applied (set HARDEN_INPUT=1 to lock the socle down)."
fi

ok "Host hardening complete."
