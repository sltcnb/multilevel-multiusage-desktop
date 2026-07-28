#!/bin/sh
# tests/test-host.sh — the host-side scripts: hardening, kiosk configuration,
# environment switching, Wi-Fi and the captive-portal helper.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== host/harden.sh =="
new_sandbox
rm -rf /etc/nftables.d
"$SANDBOX/host/harden.sh" > "$SANDBOX/harden.out" 2>&1
assert_eq "harden.sh succeeds with the default (opt-out) input firewall" 0 "$?"
assert_contains "sysctl hardening is written" /etc/sysctl.d/90-appliance-hardening.conf 'kernel.kptr_restrict=2'
assert_contains "IPv6 forwarding stays off (the egress rules are v4-only)" /etc/sysctl.d/90-appliance-hardening.conf 'net.ipv6.conf.all.forwarding=0'

# sshd hardening must apply even with the firewall off — the kiosk account has
# no password at all, so it must never be usable over the network.
mkdir -p /etc/ssh
printf 'PermitEmptyPasswords yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.orig
"$SANDBOX/host/harden.sh" > "$SANDBOX/harden2.out" 2>&1
assert_contains "an existing PermitEmptyPasswords yes is rewritten to no" /etc/ssh/sshd_config '^PermitEmptyPasswords no$'
assert_not_contains "no 'yes' variant survives" /etc/ssh/sshd_config 'PermitEmptyPasswords yes'
assert_contains "the kiosk account is denied over SSH" /etc/ssh/sshd_config '^DenyUsers kiosk$'
"$SANDBOX/host/harden.sh" > /dev/null 2>&1
assert_eq "re-running does not duplicate the DenyUsers line" 1 "$(grep -c '^DenyUsers kiosk$' /etc/ssh/sshd_config)"

# The opt-in default-drop input firewall. It runs BEFORE isolate.sh at first
# boot, so it cannot rely on /etc/nftables.d already existing.
new_sandbox
rm -rf /etc/nftables.d
cfg_set HARDEN_INPUT 1
nft flush ruleset 2>/dev/null || true
"$SANDBOX/host/harden.sh" > "$SANDBOX/hardenfw.out" 2>&1
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
"$SANDBOX/host/harden.sh" > /dev/null 2>&1
assert_contains "HOST_SSH=1 opens port 22" "$INP" 'tcp dport 22 accept'
nft flush ruleset 2>/dev/null || true

echo
echo "== host/configure.sh =="
new_sandbox
cfg_set USBGUARD 1
cfg_set YUBIKEY_ROUTER 1
mkdir -p /etc/usbguard
"$SANDBOX/host/configure.sh" > "$SANDBOX/configure.out" 2>&1
cfg_rc=$?
assert_eq "configure.sh succeeds" 0 "$cfg_rc"
KH="$(getent passwd kiosk | cut -d: -f6)"; KH="${KH:-/home/kiosk}"
assert_contains "tty1 autologins the unprivileged kiosk user, not root" /etc/inittab 'agetty --autologin kiosk'
assert_contains "the kiosk profile auto-starts X on tty1 only" "$KH/.profile" '= "/dev/tty1"'
assert_contains "and only when X is not already running" "$KH/.profile" '\-z "\$\{DISPLAY:-\}"'
assert_contains "the kiosk drives the system libvirt instance" "$KH/.profile" 'LIBVIRT_DEFAULT_URI=qemu:///system'
assert_contains "xinitrc launches i3" "$KH/.xinitrc" '^exec i3$'
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
"$SANDBOX/host/configure.sh" > /dev/null 2>&1
assert_contains "layout:variant becomes -variant" "$KH/.xinitrc" 'setxkbmap fr -variant oss'

echo
echo "== host/switching.sh =="
new_sandbox
"$SANDBOX/host/switching.sh" > "$SANDBOX/switching.out" 2>&1
sw_rc=$?
assert_eq "switching.sh succeeds" 0 "$sw_rc"
I3="$KH/.config/i3/config"
assert_contains "Super+1 switches to the first env" "$I3" 'bindsym \$mod\+1 workspace number 1'
assert_contains "Super+3 switches to the third env" "$I3" 'bindsym \$mod\+3 workspace number 3'
assert_contains "each env's viewer is launched" "$I3" "vm-viewer.sh administration"
assert_contains "the viewer is matched onto its numbered workspace" "$I3" 'move to workspace "2: DEVELOPMENT"'
assert_contains "boot lands on the first enabled env" "$I3" 'i3-msg workspace number 1'
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
assert_contains "keyd binds Super+1" /etc/keyd/default.conf 'meta\+1 = command\(/usr/local/bin/vmswitch 1\)'
assert_contains "keyd binds Super+Enter for the host shell" /etc/keyd/default.conf 'meta\+enter = command\(/usr/local/bin/vmswitch term\)'
assert_contains "keyd binds Super+p for the captive portal" /etc/keyd/default.conf 'meta\+p = command\(/usr/local/bin/vmswitch portal\)'
assert_contains "keyd binds Super+y for the USB chooser" /etc/keyd/default.conf 'meta\+y = command\(/usr/local/bin/vmswitch usb\)'
# Every overlay must switch to an empty workspace first, or it opens behind the
# focused VM and is never seen.
assert_contains "the USB chooser opens on its own workspace" /usr/local/bin/vmswitch 'usb).*workspace number 7'
assert_contains "the portal opens on its own workspace" /usr/local/bin/vmswitch 'portal).*workspace number 8'
assert_contains "the shell opens on its own workspace" /usr/local/bin/vmswitch 'term).*workspace number 9'
assert_contains "the i3 Super+y fallback also switches workspace first" "$I3" 'bindsym \$mod\+y workspace number 7'
assert_not_contains "no unexpanded placeholder is left in the i3 config" "$I3" 'HOMEDIR_APP|WS_[A-Z]+_N'
assert_contains "the trust bar names the overlay workspaces too" "$KH/.config/polybar/active-env.sh" "7) printf '%s' 'USB'"
assert_contains "vmswitch reads the real X cookie from the running i3" /usr/local/bin/vmswitch 'XAUTHORITY='

# Disabling an env removes its hotkey and viewer but not the others' numbers.
new_sandbox
cfg_set development_ENABLED 0
"$SANDBOX/host/switching.sh" > /dev/null 2>&1
assert_not_contains "a disabled env gets no viewer" "$I3" 'vm-viewer.sh development'
assert_not_contains "a disabled env gets no hotkey" /etc/keyd/default.conf 'meta\+2 ='
assert_contains "the remaining envs keep their numbers" /etc/keyd/default.conf 'meta\+3 = command\(/usr/local/bin/vmswitch 3\)'

# TRUST_BAR=0 is the documented alternative: true fullscreen, no bar.
new_sandbox
cfg_set TRUST_BAR 0
"$SANDBOX/host/switching.sh" > /dev/null 2>&1
assert_contains "TRUST_BAR=0 lets viewers go fullscreen" "$I3" 'fullscreen enable'
assert_eq "TRUST_BAR=0 launches the viewer full-screen" "--full-screen" "$(cat "$KH/.vm-viewer-fs")"

echo
echo "== host/wifi.sh =="
new_sandbox
"$SANDBOX/host/wifi.sh" > "$SANDBOX/wifi-noop.out" 2>&1
assert_eq "no SSID configured is a clean no-op (wired host)" 0 "$?"
assert_contains "and says so" "$SANDBOX/wifi-noop.out" 'skipping WiFi setup'

new_sandbox
cfg_set WIFI_SSID "TestNet"
cfg_set WIFI_PSK "supersecret"
cfg_set WIFI_IFACE "wlan0"
mkdir -p /sys/class/net 2>/dev/null || true
"$SANDBOX/host/wifi.sh" > "$SANDBOX/wifi.out" 2>&1
assert_contains "the PSK is stored hashed" /etc/wpa_supplicant/wpa_supplicant.conf 'psk=deadbeef'
assert_not_contains "the plaintext passphrase is never written" /etc/wpa_supplicant/wpa_supplicant.conf 'supersecret'
assert_mode "wpa_supplicant.conf is root-only" 600 /etc/wpa_supplicant/wpa_supplicant.conf
# A randomised MAC would lose the captive-portal session on every reassociation.
assert_contains "the hardware MAC is pinned for the captive portal" /etc/wpa_supplicant/wpa_supplicant.conf 'mac_addr=0'
assert_contains "the uplink is recorded for isolate.sh" "$SANDBOX/config.env" '^WAN_IFACE="wlan0"$'
"$SANDBOX/host/wifi.sh" > /dev/null 2>&1
assert_eq "re-running does not duplicate the interfaces stanza" \
  1 "$(grep -c '^auto wlan0$' /etc/network/interfaces)"

echo
echo "== host/captive-portal.sh =="
new_sandbox
"$SANDBOX/host/switching.sh" > /dev/null 2>&1
"$SANDBOX/host/captive-portal.sh" > "$SANDBOX/portal.out" 2>&1
assert_eq "captive-portal.sh succeeds" 0 "$?"
# It must land in the KIOSK home: /root is mode 0700 and the desktop is not root.
assert_contains "the helper is written where the kiosk user can run it" "$KH/portal-login.sh" 'PROBE='
assert_eq "the helper is owned by the kiosk user" "kiosk" "$(stat -c '%U' "$KH/portal-login.sh")"
assert_contains "it no-ops when already online" "$KH/portal-login.sh" '"\$code" = "204"'
assert_contains "it opens the redirect target the portal supplies" "$KH/portal-login.sh" 'redirect_url'
"$SANDBOX/host/captive-portal.sh" > /dev/null 2>&1
assert_eq "re-running does not duplicate the i3 binding" \
  1 "$(grep -c 'portal-login.sh' "$I3")"

summary
