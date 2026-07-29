#!/bin/sh
# =============================================================================
# host/usb-allow.sh — whitelist a USB device past the default-deny usbguard policy
# -----------------------------------------------------------------------------
# The appliance blocks all USB except input devices (keyboards/mice) + hubs.
# Use this to permanently allow a specific data device (e.g. a USB stick you want
# to hand to one VM). Persisted to /etc/usbguard/rules.conf.
#
# Usage:
#   host/usb-allow.sh list                 # show all USB devices + block/allow state
#   host/usb-allow.sh allow <device-id>    # permanently allow that device
#   host/usb-allow.sh block <device-id>    # re-block a device
#   host/usb-allow.sh                      # same as 'list'
#
# <device-id> is the leading number shown by `list` (usbguard's device rule id).
# After allowing, attach it to ONE environment only, e.g.:
#   virsh attach-device office /path/to/usb.xml
# =============================================================================
set -eu

command -v usbguard >/dev/null 2>&1 || { echo "[x] usbguard not installed."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "[x] run as root."; exit 1; }

cmd="${1:-list}"
case "$cmd" in
  list|"")
    echo "USB devices (id: state):"
    usbguard list-devices
    echo
    echo "Allow one with: host/usb-allow.sh allow <id>"
    ;;
  allow)
    [ $# -ge 2 ] || { echo "usage: usb-allow.sh allow <id>"; exit 1; }
    # -p persists the allow rule to rules.conf.
    usbguard allow-device "$2" -p
    echo "[+] Allowed + persisted device $2. Now attach it to ONE VM only:"
    echo "    virsh attach-device <env> <device.xml>"
    ;;
  block)
    [ $# -ge 2 ] || { echo "usage: usb-allow.sh block <id>"; exit 1; }
    usbguard block-device "$2" -p
    echo "[+] Blocked + persisted device $2."
    ;;
  *)
    echo "usage: usb-allow.sh [list|allow <id>|block <id>]"; exit 1 ;;
esac
