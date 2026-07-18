#!/bin/bash
# =============================================================================
# host/wifi.sh
# -----------------------------------------------------------------------------
# Bring up WiFi as the HOST uplink so the three VMs get NAT internet over it.
# WiFi does NOT weaken VM isolation: the VMs never touch wlan0 directly — they
# sit on their own isolated bridges and are NAT'd out whatever the default-route
# interface is (05 auto-detects it, which then resolves to wlan0).
#
# Run this BEFORE 05 (05 needs a working default route to detect WAN + NAT).
# On the prebuilt image, first-boot runs this automatically ONLY if WIFI_SSID
# is set in config.env; otherwise run it by hand on the appliance.
#
# SECURITY: the PSK is hashed with wpa_passphrase; plaintext PSK is not written
# to wpa_supplicant.conf. The file is chmod 600.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config
require_cmds wpa_supplicant wpa_passphrase iw

# -----------------------------------------------------------------------------
# 0. Nothing to do if no SSID configured (host stays on wired).
# -----------------------------------------------------------------------------
if [ -z "${WIFI_SSID:-}" ]; then
  warn "WIFI_SSID empty in config.env — skipping WiFi setup (host uses wired)."
  exit 0
fi

# -----------------------------------------------------------------------------
# 1. Resolve the wlan interface.
# -----------------------------------------------------------------------------
if [ "${WIFI_IFACE:-auto}" = "auto" ]; then
  WIFI_IFACE="$(ls /sys/class/net | grep -m1 '^wl' || true)"
  [ -n "$WIFI_IFACE" ] || die "No wlan interface found. Missing firmware/driver? (see 00/01 WIFI_FIRMWARE_PKG)"
fi
set_kv WIFI_IFACE "$WIFI_IFACE"
log "WiFi interface: $WIFI_IFACE"

# Sanity: firmware present? If the NIC has no driver bound, warn loudly.
if ! iw dev "$WIFI_IFACE" info >/dev/null 2>&1; then
  warn "iw can't query $WIFI_IFACE — firmware/driver may be missing."
fi

# -----------------------------------------------------------------------------
# 2. Regulatory domain.
# -----------------------------------------------------------------------------
iw reg set "${WIFI_COUNTRY:-00}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 3. wpa_supplicant.conf — PSK hashed, never plaintext. chmod 600.
#    wpa_passphrase emits a network{} block with psk=<hash>. We strip the
#    commented plaintext line it adds for safety.
# -----------------------------------------------------------------------------
WPA_DIR="/etc/wpa_supplicant"
WPA_CONF="$WPA_DIR/wpa_supplicant.conf"
mkdir -p "$WPA_DIR"
log "Writing $WPA_CONF (PSK hashed) ..."
{
  echo "ctrl_interface=/var/run/wpa_supplicant"
  echo "ctrl_interface_group=wheel"
  echo "country=${WIFI_COUNTRY:-00}"
  echo "update_config=1"
  # STABLE MAC (critical for captive portals): a captive portal authorizes the
  # client MAC after browser login. If the MAC randomizes, the portal session is
  # lost on every (re)association and you'd have to log in constantly. Force the
  # permanent hardware MAC so the Entra-portal session persists for all VMs
  # (they NAT out this single MAC). See host/captive-portal.sh.
  echo "mac_addr=0"
  echo "preassoc_mac_addr=0"
  if [ -n "${WIFI_PSK:-}" ]; then
    # Hash PSK; drop the plaintext "#psk=..." comment line wpa_passphrase adds.
    wpa_passphrase "$WIFI_SSID" "$WIFI_PSK" | grep -v '^\s*#psk='
  else
    # Open network (no PSK).
    printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$WIFI_SSID"
  fi
} > "$WPA_CONF"
chmod 600 "$WPA_CONF"

# -----------------------------------------------------------------------------
# 4. /etc/network/interfaces — wlan via dhcp, launching wpa_supplicant.
#    Idempotent: replace any existing stanza for this iface.
# -----------------------------------------------------------------------------
IF_FILE="/etc/network/interfaces"
touch "$IF_FILE"
log "Configuring $IF_FILE for $WIFI_IFACE ..."
# Remove any prior auto/iface lines for this iface (simple stanza strip).
awk -v ifc="$WIFI_IFACE" '
  $0 ~ ("^auto[ \t]+" ifc "$")  {skip=1; next}
  $0 ~ ("^iface[ \t]+" ifc "[ \t]") {skip=1; next}
  /^auto|^iface/ {skip=0}
  skip==1 && /^[ \t]/ {next}
  skip==1 {skip=0}
  {print}
' "$IF_FILE" > "$IF_FILE.tmp" && mv "$IF_FILE.tmp" "$IF_FILE"

cat >> "$IF_FILE" <<EOF

auto $WIFI_IFACE
iface $WIFI_IFACE inet dhcp
    pre-up wpa_supplicant -B -i $WIFI_IFACE -c $WPA_CONF -Dnl80211,wext
    post-down killall -q wpa_supplicant || true
EOF

# -----------------------------------------------------------------------------
# 5. Enable services at boot (OpenRC / systemd).
# -----------------------------------------------------------------------------
if command -v rc-update >/dev/null 2>&1; then
  rc-update add wpa_supplicant boot 2>/dev/null || true
  rc-update add networking boot 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
  systemctl enable wpa_supplicant 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 6. Bring it up now.
# -----------------------------------------------------------------------------
log "Bringing up $WIFI_IFACE ..."
if command -v ifup >/dev/null 2>&1; then
  ifdown "$WIFI_IFACE" 2>/dev/null || true
  ifup "$WIFI_IFACE" 2>/dev/null || warn "ifup failed; check dmesg / firmware."
fi

# Record the uplink so 05 uses it explicitly (belt-and-suspenders vs auto).
set_kv WAN_IFACE "$WIFI_IFACE"

# -----------------------------------------------------------------------------
# 7. Verify connectivity (best-effort).
# -----------------------------------------------------------------------------
sleep 5
if ip route show default 2>/dev/null | grep -q "$WIFI_IFACE"; then
  ok "Default route via $WIFI_IFACE."
else
  warn "No default route via $WIFI_IFACE yet (association/DHCP may be pending)."
fi
if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
  ok "Host internet OK over WiFi."
else
  warn "Host cannot reach internet yet. Check SSID/PSK, signal, firmware."
fi

cat <<EOF

WiFi configured. Uplink=$WIFI_IFACE. Now run/re-run:
    ./environments/isolate.sh
so NAT + inter-VM DROP rules bind to $WIFI_IFACE.
EOF
