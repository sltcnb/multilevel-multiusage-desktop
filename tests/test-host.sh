#!/bin/sh
# tests/test-host.sh — the host-side scripts: hardening, kiosk configuration,
# environment switching, Wi-Fi and the captive-portal helper.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== host/harden.sh =="
new_sandbox
rm -rf /etc/nftables.d
"$SANDBOX/src/host.sh" harden > "$SANDBOX/harden.out" 2>&1
assert_eq "harden.sh succeeds with the default (opt-out) input firewall" 0 "$?"
assert_contains "sysctl hardening is written" /etc/sysctl.d/90-appliance-hardening.conf 'kernel.kptr_restrict=2'
assert_contains "IPv6 forwarding stays off (the egress rules are v4-only)" /etc/sysctl.d/90-appliance-hardening.conf 'net.ipv6.conf.all.forwarding=0'

# sshd hardening must apply even with the firewall off — the kiosk account has
# no password at all, so it must never be usable over the network.
mkdir -p /etc/ssh
printf 'PermitEmptyPasswords yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.orig
"$SANDBOX/src/host.sh" harden > "$SANDBOX/harden2.out" 2>&1
assert_contains "an existing PermitEmptyPasswords yes is rewritten to no" /etc/ssh/sshd_config '^PermitEmptyPasswords no$'
assert_not_contains "no 'yes' variant survives" /etc/ssh/sshd_config 'PermitEmptyPasswords yes'
assert_contains "the kiosk account is denied over SSH" /etc/ssh/sshd_config '^DenyUsers kiosk$'
"$SANDBOX/src/host.sh" harden > /dev/null 2>&1
assert_eq "re-running does not duplicate the DenyUsers line" 1 "$(grep -c '^DenyUsers kiosk$' /etc/ssh/sshd_config)"

# The opt-in default-drop input firewall. It runs BEFORE isolate.sh at first
# boot, so it cannot rely on /etc/nftables.d already existing.
new_sandbox
rm -rf /etc/nftables.d
cfg_set HARDEN_INPUT 1
nft flush ruleset 2>/dev/null || true
"$SANDBOX/src/host.sh" harden > "$SANDBOX/hardenfw.out" 2>&1
fw_rc=$?
assert_eq "HARDEN_INPUT=1 succeeds even when /etc/nftables.d is absent" 0 "$fw_rc"
assert_ok "the host input ruleset loads into a real kernel nftables" \
  nft -f /etc/nftables.d/appliance-host-input.nft
INP=/etc/nftables.d/appliance-host-input.nft
assert_contains "the input chain defaults to drop" "$INP" 'policy drop'
assert_contains "loopback is allowed" "$INP" 'iif "lo" accept'
# Guests reach the host only as their gateway. nftables evaluates every base
# chain on the hook and any drop is final, so libvirt's own accepts do not save
# these — without explicit rules the guests get no DHCP lease and no resolver.
assert_contains "guest DHCP to the bridge gateway is allowed" "$INP" 'iifname "virbr\*" udp dport 67 accept'
assert_contains "guest DNS (udp) to the bridge gateway is allowed" "$INP" 'iifname "virbr\*" udp dport 53 accept'
assert_contains "guest DNS (tcp) to the bridge gateway is allowed" "$INP" 'iifname "virbr\*" tcp dport 53 accept'
assert_not_contains "ssh stays closed unless HOST_SSH=1" "$INP" 'tcp dport 22 accept'
new_sandbox
cfg_set HARDEN_INPUT 1; cfg_set HOST_SSH 1
"$SANDBOX/src/host.sh" harden > /dev/null 2>&1
assert_contains "HOST_SSH=1 opens port 22" "$INP" 'tcp dport 22 accept'
nft flush ruleset 2>/dev/null || true

echo
echo "== host/configure.sh =="
new_sandbox
cfg_set USBGUARD 1
cfg_set YUBIKEY_ROUTER 1
mkdir -p /etc/usbguard
"$SANDBOX/src/host.sh" configure > "$SANDBOX/configure.out" 2>&1
cfg_rc=$?
assert_eq "configure.sh succeeds" 0 "$cfg_rc"
KH="$(getent passwd kiosk | cut -d: -f6)"; KH="${KH:-/home/kiosk}"
assert_contains "tty1 autologins the unprivileged kiosk user, not root" /etc/inittab 'agetty --autologin kiosk'
assert_contains "the kiosk profile auto-starts X on tty1 only" "$KH/.profile" '= "/dev/tty1"'
assert_contains "and only when X is not already running" "$KH/.profile" '\-z "\$\{DISPLAY:-\}"'
assert_contains "the kiosk drives the system libvirt instance" "$KH/.profile" 'LIBVIRT_DEFAULT_URI=qemu:///system'
# virt-viewer (GtkApplication) needs a session D-Bus or its window never maps;
# the kiosk session has none, so start it under dbus-run-session.
assert_contains "xinitrc starts i3 under a session D-Bus" "$KH/.xinitrc" 'exec dbus-run-session -- i3'
assert_not_contains "the invalid -gtk-icon-size property is gone (GTK parse error)" "$KH/.config/gtk-3.0/gtk.css" 'gtk-icon-size'
assert_contains "the configured keyboard layout is applied" "$KH/.xinitrc" 'setxkbmap us'
assert_contains "usbguard defaults to blocking unknown devices" /etc/usbguard/usbguard-daemon.conf 'ImplicitPolicyTarget=block'
assert_contains "input devices stay allowed so the machine remains usable" /etc/usbguard/rules.conf 'allow with-interface one-of \{ 03:\*:\* \}'
assert_contains "YubiKeys are admitted past the default deny" /etc/usbguard/rules.conf 'allow id 1050:\*'
# One insert must pop exactly one chooser: without DEVTYPE the rule also fires
# for each USB interface the key exposes.
assert_contains "the udev rule matches the device, not each USB interface" \
  /etc/udev/rules.d/99-yubikey-router.rules 'ENV\{DEVTYPE\}=="usb_device"'
assert_contains "the chooser reads the live X cookie (startx uses .serverauth)" \
  /usr/local/bin/yubikey-plugged 'proc/\$pid/environ'
assert_contains "a keyboard layout with a variant is split correctly" "$KH/.xinitrc" 'setxkbmap us'
new_sandbox
cfg_set KEYBOARD_LAYOUT "fr:oss"
"$SANDBOX/src/host.sh" configure > /dev/null 2>&1
assert_contains "layout:variant becomes -variant" "$KH/.xinitrc" 'setxkbmap fr -variant oss'

echo
echo "== host/switching.sh =="
new_sandbox
"$SANDBOX/src/host.sh" switching > "$SANDBOX/switching.out" 2>&1
sw_rc=$?
assert_eq "switching.sh succeeds" 0 "$sw_rc"
I3="$KH/.config/i3/config"
# Switching is Ctrl+Alt+<n> (keyd, below X); Super/Meta is left to the guest
# (Windows uses Super+1..9). So i3 must NOT bind Super+<n> for switching.
assert_not_contains "Super+<n> is NOT bound for switching in i3 (left to the guest)" "$I3" 'bindsym \$mod\+1 workspace'
assert_contains "each env's viewer is launched" "$I3" "vm-viewer.sh administration"
assert_contains "the viewer is matched onto its NUMBERED workspace (a named one is a different workspace than the numbered one)" "$I3" "move to workspace number 2"
assert_contains "boot lands on the first enabled env" "$I3" 'i3-msg workspace number 1'
# Super+w lets the unprivileged kiosk add a Wi-Fi network (work-from-home).
assert_contains "Super+w is bound to the add-Wi-Fi helper" "$I3" 'bindsym \$mod\+w .*Add Wi-Fi'
assert_contains "the bind points at the kiosk add-wifi helper (path baked)" "$I3" "$KH/add-wifi.sh"
assert_contains "the add-wifi helper is written to the kiosk home" "$KH/add-wifi.sh" 'wpa_cli add_network'
assert_eq "the add-wifi helper is owned by the kiosk user" "kiosk" "$(stat -c '%U' "$KH/add-wifi.sh")"
assert_ok "the add-wifi helper is executable" test -x "$KH/add-wifi.sh"
# The trust bar is the ANSSI requirement that you always know which environment
# you are in — a viewer must never be able to cover it.
assert_contains "a viewer is prevented from going fullscreen over the trust bar" "$I3" 'fullscreen disable'
assert_contains "polybar reserves a strut rather than floating over the VM" "$KH/.config/polybar/config.ini" 'override-redirect = false'
assert_contains "the trust bar labels every environment" "$KH/.config/polybar/active-env.sh" "printf '%s' 'ADMINISTRATION'"
assert_contains "the trust bar re-renders on every workspace change" "$KH/.config/polybar/active-env.sh" 'i3-msg -t subscribe'
assert_contains "the clipboard does not cross security domains" "$KH/.config/virt-viewer/settings" 'share-clipboard=false'

# Hotkeys must be delivered by keyd (evdev, below X): SPICE grabs the X keyboard
# whenever a guest is focused, which is the normal state of this kiosk, so an
# i3-only bindsym never fires.
assert_contains "keyd binds Ctrl+Alt+1 to switch to env 1" /etc/keyd/default.conf 'leftcontrol\+leftalt\+1 = command\(/usr/local/bin/vmswitch 1\)'
assert_not_contains "Super+1 is NOT a keyd switch chord (left to the guest)" /etc/keyd/default.conf 'leftmeta\+1 = command'
assert_contains "keyd binds Super+Enter for the host shell" /etc/keyd/default.conf 'leftmeta\+enter = command\(/usr/local/bin/vmswitch term\)'
assert_contains "keyd binds Super+p for the captive portal" /etc/keyd/default.conf 'leftmeta\+p = command\(/usr/local/bin/vmswitch portal\)'
assert_contains "keyd binds Super+y for the USB chooser" /etc/keyd/default.conf 'leftmeta\+y = command\(/usr/local/bin/vmswitch usb\)'
# Every overlay must switch to an empty workspace first, or it opens behind the
# focused VM and is never seen.
assert_contains "the USB chooser opens on its own workspace" /usr/local/bin/vmswitch 'usb).*workspace number 7'
assert_contains "the portal opens on its own workspace" /usr/local/bin/vmswitch 'portal).*workspace number 8'
assert_contains "the shell opens on its own workspace" /usr/local/bin/vmswitch 'term).*workspace number 9'
assert_contains "the i3 Super+y fallback also switches workspace first" "$I3" 'bindsym \$mod\+y workspace number 7'
assert_not_contains "no unexpanded placeholder is left in the i3 config" "$I3" 'HOMEDIR_APP|WS_[A-Z]+_N'
assert_contains "the trust bar names the overlay workspaces too" "$KH/.config/polybar/active-env.sh" "7) printf '%s' 'USB'"
assert_contains "vmswitch reads the real X cookie from the running i3" /usr/local/bin/vmswitch 'XAUTHORITY='

# The pill also carries each env's security posture: the egress/VPN lookups are
# baked case statements (render re-runs on every workspace event, so it must
# never re-read config.env), plus the CONTRACT A isolation module on the right.
assert_contains "active-env.sh bakes the egress lookup" "$KH/.config/polybar/active-env.sh" 'egress_of\(\)'
assert_contains "active-env.sh bakes the VPN-intent lookup" "$KH/.config/polybar/active-env.sh" 'vpn_wanted\(\)'
assert_contains "the pill flags whitelist egress as filtered" "$KH/.config/polybar/active-env.sh" 'filtered'
assert_contains "the pill flags a wanted-but-absent tunnel" "$KH/.config/polybar/active-env.sh" 'vpn down'
assert_contains "the isolation module sits on the trust bar" "$KH/.config/polybar/config.ini" 'modules-right = isolation'
assert_contains "the isolation module runs the generated script" "$KH/.config/polybar/config.ini" 'polybar/isolation\.sh'
assert_not_contains "no cpu percentage module (host load is meaningless here)" "$KH/.config/polybar/config.ini" 'internal/cpu'
assert_not_contains "no memory percentage module" "$KH/.config/polybar/config.ini" 'internal/memory'
assert_contains "the pill is padded to a fixed width (no reflow on switch)" "$KH/.config/polybar/active-env.sh" 'PAD_WIDTH='
assert_contains_fixed "render() applies the fixed width" "$KH/.config/polybar/active-env.sh" 'printf "%-${PAD_WIDTH}s"'
assert_contains "virt-viewer's windowed header is collapsed via gtk.css" "$KH/.config/gtk-3.0/gtk.css" 'headerbar'

# The baked lookups must resolve per config.env: a whitelist env reports
# whitelist egress, and <env>_VPN=1 marks that workspace as wanting a tunnel.
new_sandbox
cfg_set office_EGRESS_MODE whitelist
cfg_set administration_VPN 1
"$SANDBOX/src/host.sh" switching > /dev/null 2>&1
AE="$KH/.config/polybar/active-env.sh"
# Source only the lookup header (everything before render()) so the lookups can
# be exercised without a running i3.
awk '/^render/{exit} {print}' "$AE" > "$SANDBOX/lookups.sh"
. "$SANDBOX/lookups.sh"
assert_eq "egress_of resolves the whitelist env" "whitelist" "$(egress_of 1)"
assert_eq "egress_of keeps an open env at all" "all" "$(egress_of 2)"
assert_eq "egress_of defaults an unknown workspace to all" "all" "$(egress_of 42)"
assert_contains "the VPN=1 env is baked as wanting a tunnel" "$AE" '3\) return 0'
if vpn_wanted 3; then _vpn3=0; else _vpn3=$?; fi
assert_eq "vpn_wanted is true for the VPN=1 env" 0 "$_vpn3"
if vpn_wanted 1; then _vpn1=0; else _vpn1=$?; fi
assert_eq "vpn_wanted is false for a non-VPN env" 1 "$_vpn1"

# The isolation module maps CONTRACT A states to bar labels and must never
# error: a missing or unparsable status file is UNKNOWN, never a crash.
ISO="$KH/.config/polybar/isolation.sh"
mkdir -p "$SANDBOX/run"
printf 'OK\t1700000000\tall envs isolated\n' > "$SANDBOX/run/st"
ISOLATION_STATUS_FILE="$SANDBOX/run/st" sh "$ISO" > "$SANDBOX/iso.out" 2> "$SANDBOX/iso.err"
assert_eq "the isolation module exits 0 on OK" 0 "$?"
assert_eq "OK renders NOTHING (quiet by design — no green pill)" "" "$(cat "$SANDBOX/iso.out")"
assert_eq "OK stays silent on stderr" "" "$(cat "$SANDBOX/iso.err")"
printf 'FAIL\t1700000001\tdevelopment escaped\n' > "$SANDBOX/run/st"
ISOLATION_STATUS_FILE="$SANDBOX/run/st" sh "$ISO" > "$SANDBOX/iso.out" 2> "$SANDBOX/iso.err"
assert_contains "FAIL renders red 'ISOLATION FAIL'" "$SANDBOX/iso.out" '#ef4444.*ISOLATION FAIL'
rm -f "$SANDBOX/run/st"
ISOLATION_STATUS_FILE="$SANDBOX/run/st" sh "$ISO" > "$SANDBOX/iso.out" 2> "$SANDBOX/iso.err"
assert_eq "a missing status file still exits 0" 0 "$?"
assert_contains "a missing status file renders 'isolation ?'" "$SANDBOX/iso.out" 'isolation \?'
assert_eq "a missing status file stays silent on stderr" "" "$(cat "$SANDBOX/iso.err")"
printf 'garbage\n' > "$SANDBOX/run/st"
ISOLATION_STATUS_FILE="$SANDBOX/run/st" sh "$ISO" > "$SANDBOX/iso.out" 2> "$SANDBOX/iso.err"
assert_contains "an unparsable status file renders 'isolation ?'" "$SANDBOX/iso.out" 'isolation \?'

# Disabling an env removes its hotkey and viewer but not the others' numbers.
new_sandbox
cfg_set development_ENABLED 0
"$SANDBOX/src/host.sh" switching > /dev/null 2>&1
assert_not_contains "a disabled env gets no viewer" "$I3" 'vm-viewer.sh development'
assert_not_contains "a disabled env gets no hotkey" /etc/keyd/default.conf 'leftcontrol\+leftalt\+2 ='
assert_contains "the remaining envs keep their numbers" /etc/keyd/default.conf 'leftcontrol\+leftalt\+3 = command\(/usr/local/bin/vmswitch 3\)'

# TRUST_BAR=0 is the documented alternative: true fullscreen, no bar.
new_sandbox
cfg_set TRUST_BAR 0
"$SANDBOX/src/host.sh" switching > /dev/null 2>&1
assert_contains "TRUST_BAR=0 lets viewers go fullscreen" "$I3" 'fullscreen enable'
assert_eq "TRUST_BAR=0 launches the viewer full-screen" "--full-screen" "$(cat "$KH/.vm-viewer-fs")"

echo
echo "== host/wifi.sh =="
new_sandbox
"$SANDBOX/src/host.sh" wifi > "$SANDBOX/wifi-noop.out" 2>&1
assert_eq "no SSID configured is a clean no-op (wired host)" 0 "$?"
assert_contains "and says so" "$SANDBOX/wifi-noop.out" 'skipping WiFi setup'

new_sandbox
cfg_set WIFI_SSID "TestNet"
cfg_set WIFI_PSK "supersecret"
cfg_set WIFI_IFACE "wlan0"
mkdir -p /sys/class/net 2>/dev/null || true
"$SANDBOX/src/host.sh" wifi > "$SANDBOX/wifi.out" 2>&1
assert_contains "the PSK is stored hashed" /etc/wpa_supplicant/wpa_supplicant.conf 'psk=deadbeef'
assert_not_contains "the plaintext passphrase is never written" /etc/wpa_supplicant/wpa_supplicant.conf 'supersecret'
assert_mode "wpa_supplicant.conf is root-only" 600 /etc/wpa_supplicant/wpa_supplicant.conf
# A randomised MAC would lose the captive-portal session on every reassociation.
assert_contains "the hardware MAC is pinned for the captive portal" /etc/wpa_supplicant/wpa_supplicant.conf 'mac_addr=0'
# The control socket is group netdev so the unprivileged kiosk (Super+w) can add
# networks with wpa_cli — not wheel, which would imply admin privilege.
assert_contains "the wpa control socket is group netdev (kiosk-manageable)" /etc/wpa_supplicant/wpa_supplicant.conf 'ctrl_interface_group=netdev'
# wifi must NOT pin WAN_IFACE to the wlan: a Wi-Fi-configured host actually on
# Ethernet would otherwise NAT the guests out a dead interface. It stays "auto"
# so isolate re-detects the real default-route uplink each run.
assert_contains "wifi leaves WAN_IFACE=auto (isolate detects the real uplink)" "$SANDBOX/config.env" '^WAN_IFACE="auto"$'
assert_not_contains "wifi does not pin WAN_IFACE to the wlan" "$SANDBOX/config.env" '^WAN_IFACE="wlan0"$'
"$SANDBOX/src/host.sh" wifi > /dev/null 2>&1
assert_eq "re-running does not duplicate the interfaces stanza" \
  1 "$(grep -c '^auto wlan0$' /etc/network/interfaces)"

echo
echo "== host/captive-portal.sh =="
new_sandbox
"$SANDBOX/src/host.sh" switching > /dev/null 2>&1
"$SANDBOX/src/host.sh" captive-portal > "$SANDBOX/portal.out" 2>&1
assert_eq "captive-portal.sh succeeds" 0 "$?"
# It must land in the KIOSK home: /root is mode 0700 and the desktop is not root.
assert_contains "the helper is written where the kiosk user can run it" "$KH/portal-login.sh" 'PROBE='
assert_eq "the helper is owned by the kiosk user" "kiosk" "$(stat -c '%U' "$KH/portal-login.sh")"
assert_contains "it no-ops when already online" "$KH/portal-login.sh" '"\$code" = "204"'
assert_contains "it opens the redirect target the portal supplies" "$KH/portal-login.sh" 'redirect_url'
"$SANDBOX/src/host.sh" captive-portal > /dev/null 2>&1
assert_eq "re-running does not duplicate the i3 binding" \
  1 "$(grep -c 'portal-login.sh' "$I3")"

summary
