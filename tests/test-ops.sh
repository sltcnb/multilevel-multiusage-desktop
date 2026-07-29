#!/bin/sh
# tests/test-ops.sh — the day-two operator tools: the setup menu, the USB
# chooser, live password changes, the per-env VPN and secret scrubbing.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== setup-machine.sh =="
new_sandbox
# With no arguments setup-machine.sh now execs host/tui.sh (covered in test-tui.sh);
# the classic numbered menu these assertions exercise lives behind --menu.
"$SANDBOX/setup-machine.sh" --menu </dev/null > "$SANDBOX/menu.out" 2>&1
assert_contains "the menu lists the operator steps in order" "$SANDBOX/menu.out" '3\) Create the VMs'
assert_contains "the menu states the ordering rule that matters" "$SANDBOX/menu.out" 'First run order'
assert_fails "an unknown step is rejected" "$SANDBOX/setup-machine.sh" 99
# Extra words on the line are forwarded, so "5 office" targets one env.
cat > "$SANDBOX/environments/set-guest-password.sh" <<'EOF'
#!/bin/sh
echo "ARGS:$*"
EOF
chmod +x "$SANDBOX/environments/set-guest-password.sh"
assert_eq "arguments are forwarded to the step (direct mode)" \
  "ARGS:office" "$("$SANDBOX/setup-machine.sh" 5 office 2>&1)"
assert_eq "arguments are forwarded to the step (menu mode)" \
  "ARGS:office" "$(printf '5 office\n' | "$SANDBOX/setup-machine.sh" --menu 2>&1 | tail -1 | sed 's/.*q to quit\]: //')"

echo
echo "== host/usb-to-vm.sh =="
new_sandbox
touch "$SANDBOX/stub-state/dom-office" "$SANDBOX/stub-state/dom-development" "$SANDBOX/stub-state/dom-administration"
printf '2\n' | "$SANDBOX/host/usb-to-vm.sh" > "$SANDBOX/usb.out" 2>&1
assert_contains "the chooser lists every environment" "$SANDBOX/usb.out" '2) development'
assert_contains "the key is attached to the chosen env" "$STUB_LOG" 'virsh attach-device development'
# ANSSI peripheral compartmentalisation: never shared across environments.
assert_contains "and detached from the others (office)" "$STUB_LOG" 'virsh detach-device office'
assert_contains "and detached from the others (administration)" "$STUB_LOG" 'virsh detach-device administration'
assert_not_contains "it is not detached from the env it was just given to" "$STUB_LOG" 'virsh detach-device development'

# A non-numeric choice used to index an awk field and silently detach everywhere.
new_sandbox
touch "$SANDBOX/stub-state/dom-office"
printf 'x\n' | "$SANDBOX/host/usb-to-vm.sh" > "$SANDBOX/usbbad.out" 2>&1
assert_contains "a non-numeric choice is rejected" "$SANDBOX/usbbad.out" 'invalid choice'
assert_not_contains "and detaches nothing" "$STUB_LOG" 'detach-device'
printf '9\n' | "$SANDBOX/host/usb-to-vm.sh" > "$SANDBOX/usbrange.out" 2>&1
assert_contains "an out-of-range choice is rejected" "$SANDBOX/usbrange.out" 'invalid choice'

# The Super+y path runs as the kiosk user, which cannot read the 0600 config.
new_sandbox
touch "$SANDBOX/stub-state/dom-office" "$SANDBOX/stub-state/dom-development"
chmod 600 "$SANDBOX/config.env"
if id kiosk >/dev/null 2>&1; then
  chmod -R a+rX "$SANDBOX" 2>/dev/null || true
  chmod a+w "$STUB_LOG" "$STUB_STATE" 2>/dev/null || true
  chmod 600 "$SANDBOX/config.env"
  # With config.env out of reach the env list comes from libvirt instead, so the
  # order is libvirt's — what matters is that the chooser runs and routes the key
  # rather than dying on an unreadable config.
  out="$(printf '1\n' | su kiosk -s /bin/sh -c "PATH='$PATH' STUB_LOG='$STUB_LOG' STUB_STATE='$STUB_STATE' '$SANDBOX/host/usb-to-vm.sh'" 2>&1)"
  case "$out" in
    *"YubiKey 1050:0407 -> "*) _g "the chooser still works for the kiosk user (config.env unreadable)" ;;
    *) _b "the chooser still works for the kiosk user (config.env unreadable)"
       printf '        got: %s\n' "$out" ;;
  esac
else
  _g "kiosk user absent in this container — skipping the unprivileged chooser check"
fi

echo
echo "== environments/set-guest-password.sh =="
new_sandbox
touch "$SANDBOX/stub-state/dom-office" "$SANDBOX/stub-state/dom-development" "$SANDBOX/stub-state/dom-administration"
"$SANDBOX/environments/set-guest-password.sh" all 'NewPw!23' > "$SANDBOX/pw.out" 2>&1
assert_eq "changing every env's password succeeds" 0 "$?"
assert_contains "the guest account is changed" "$STUB_LOG" 'virsh set-user-password office operator NewPw!23'
assert_contains "root inside the guest is changed too by default" "$STUB_LOG" 'virsh set-user-password office root NewPw!23'
: > "$STUB_LOG"
NO_ROOT=1 "$SANDBOX/environments/set-guest-password.sh" office 'OnlyUser1' > /dev/null 2>&1
assert_contains "NO_ROOT=1 changes only the guest account" "$STUB_LOG" 'set-user-password office operator OnlyUser1'
assert_not_contains "NO_ROOT=1 leaves root alone" "$STUB_LOG" 'set-user-password office root'
assert_fails "an empty password is refused" \
  sh -c "printf '\n' | '$SANDBOX/environments/set-guest-password.sh' office"
new_sandbox
assert_fails "a missing domain is reported as a failure" \
  "$SANDBOX/environments/set-guest-password.sh" office 'x'

echo
echo "== environments/vpn.sh =="
new_sandbox
"$SANDBOX/environments/vpn.sh" > "$SANDBOX/vpn-noop.out" 2>&1
assert_eq "no env has VPN=1 — clean no-op" 0 "$?"
assert_contains "and says so" "$SANDBOX/vpn-noop.out" 'per-env VPN disabled'

new_sandbox
cfg_set administration_VPN 1
cfg_set administration_VPN_PRIVKEY "aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkMTI="
cfg_set administration_VPN_ADDRESS "10.9.3.2/32"
cfg_set administration_VPN_PUBKEY "cGVlcnB1YmtleXBlZXJwdWJrZXlwZWVycHVia2V5MTI="
cfg_set administration_VPN_ENDPOINT "vpn.example.test:51820"
rm -rf /etc/nftables.d
nft flush ruleset 2>/dev/null || true
"$SANDBOX/environments/vpn.sh" > "$SANDBOX/vpn.out" 2>&1
vpn_rc=$?
assert_eq "vpn.sh succeeds" 0 "$vpn_rc"
assert_ok "the VPN ruleset loads into a real kernel nftables" nft -f /etc/nftables.d/appliance-vpn.nft
V=/etc/nftables.d/appliance-vpn.nft
# Fail-closed is the whole point: if the tunnel is down the env has no internet
# rather than quietly falling back to the normal uplink.
assert_contains "direct WAN egress is dropped for the VPN'd env" "$V" 'ip saddr 10.10.3.0/24 oifname "wlan0" counter drop'
assert_contains "only the tunnel is accepted" "$V" 'ip saddr 10.10.3.0/24 oifname "wg3" accept'
assert_contains "traffic is masqueraded out the tunnel" "$V" 'ip saddr 10.10.3.0/24 oifname "wg3" masquerade'
assert_contains "the VPN table is evaluated before the isolation table" "$V" 'hook forward priority -2'
assert_contains "policy routing sends the env's traffic to its own table" "$STUB_LOG" 'ip rule add from 10.10.3.0/24 lookup 103'
assert_contains "that table's default route is the tunnel" "$STUB_LOG" 'ip route replace default dev wg3 table 103'
assert_mode "the WireGuard private key is root-only" 600 /etc/wireguard/wg3.conf
assert_contains "the tunnel config carries the peer endpoint" /etc/wireguard/wg3.conf 'Endpoint = vpn.example.test:51820'
# The nft lock persists on its own; without a boot service the tunnel would not
# come back, leaving the env permanently offline behind a fail-closed drop.
if [ -f /etc/init.d/appliance-vpn ] || [ -f /etc/systemd/system/appliance-vpn.service ]; then
  _g "a boot service is installed so the tunnels survive a reboot"
else
  _b "a boot service is installed so the tunnels survive a reboot"
fi
new_sandbox
cfg_set administration_VPN 1     # VPN=1 but no keys
"$SANDBOX/environments/vpn.sh" > "$SANDBOX/vpn-incomplete.out" 2>&1
assert_contains "an incomplete VPN config is skipped with a warning" "$SANDBOX/vpn-incomplete.out" 'missing PRIVKEY/ADDRESS/PUBKEY/ENDPOINT'
nft flush ruleset 2>/dev/null || true

echo
echo "== environments/scrub-secrets.sh =="
new_sandbox
mkdir -p "$SANDBOX/images"
for e in office development administration; do
  touch "$SANDBOX/stub-state/dom-$e" "$SANDBOX/images/$e-seed.iso"
  printf ' vda      %s/images/%s.qcow2\n sda      %s/images/%s-seed.iso\n' \
    "$SANDBOX" "$e" "$SANDBOX" "$e" > "$SANDBOX/stub-state/blk-$e"
done
printf 'GUEST_PASSWORD=secret\n' > /root/generated-secrets.txt
SCRUB_SEEDS=1 "$SANDBOX/environments/scrub-secrets.sh" > "$SANDBOX/scrub.out" 2>&1
assert_eq "scrub-secrets.sh succeeds" 0 "$?"
assert_contains "the guest password is blanked" "$SANDBOX/config.env" '^GUEST_PASSWORD=""$'
assert_contains "the Wi-Fi PSK is blanked" "$SANDBOX/config.env" '^WIFI_PSK=""$'
assert_contains "the structural config is kept" "$SANDBOX/config.env" '^ENVS='
if [ -f /root/generated-secrets.txt ]; then
  _b "the generated-secrets note is removed"
else
  _g "the generated-secrets note is removed"
fi
# domblklist prints two columns, so the target device is $1. Reading $3 matched
# nothing: the detach silently no-opped and the rm then left the domain XML
# pointing at a deleted ISO, which makes the next virsh start fail.
assert_contains "the seed cdrom is detached by its real target device" "$STUB_LOG" 'virsh detach-disk office sda --config'
if [ -f "$SANDBOX/images/office-seed.iso" ]; then
  _b "the seed ISO is removed once nothing references it"
else
  _g "the seed ISO is removed once nothing references it"
fi

# If the detach cannot happen, the ISO must STAY — a domain XML pointing at a
# deleted cdrom fails to start, which is worse than a leftover seed file.
new_sandbox
mkdir -p "$SANDBOX/images"
touch "$SANDBOX/stub-state/dom-office" "$SANDBOX/images/office-seed.iso"
printf ' sda      %s/images/office-seed.iso\n' "$SANDBOX" > "$SANDBOX/stub-state/blk-office"
cfg_set ENVS "office"
SCRUB_SEEDS=1 STUB_DETACH_FAIL=1 "$SANDBOX/environments/scrub-secrets.sh" > "$SANDBOX/scrubfail.out" 2>&1
assert_contains "a failed detach is reported" "$SANDBOX/scrubfail.out" 'could not detach seed cdrom'
if [ -f "$SANDBOX/images/office-seed.iso" ]; then
  _g "a seed that is still referenced is left in place"
else
  _b "a seed that is still referenced is left in place"
fi

summary
