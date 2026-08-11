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

HERE="$(cd "$(dirname "$0")" && pwd)"
# Source the shared library for audit_event. Fall back gracefully if the tree is
# laid out differently (older/flat appliances) so listing still works.
if [ -f "$HERE/../lib/common.sh" ]; then . "$HERE/../lib/common.sh"
elif [ -f "$HERE/lib/common.sh" ]; then . "$HERE/lib/common.sh"
else audit_event() { :; }; fi

command -v usbguard >/dev/null 2>&1 || { echo "[x] usbguard not installed."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "[x] run as root."; exit 1; }

# Who is granting the derogation (T-13 wants USB exceptions logged DATED and BY
# NAME). SUDO_USER is the human behind a sudo; else the login name; else uid.
_actor="${SUDO_USER:-$(logname 2>/dev/null || id -un 2>/dev/null || id -u)}"

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
    # Record the derogation: timestamped (audit_event stamps UTC) and named, so a
    # USB exception is never anonymous or undated (T-13). Capture the device's
    # descriptor line too, so the log says WHAT was allowed, not just its id.
    _dev="$(usbguard list-devices 2>/dev/null | awk -v i="$2" '$1==i":"||$1==i {sub(/^[0-9]+: */,""); print; exit}')"
    audit_event usb-derogation action=allow id="$2" by="$_actor" device="${_dev:-unknown}"
    echo "[+] Allowed + persisted device $2 (logged: by $_actor). Now attach it to ONE VM only:"
    echo "    virsh attach-device <env> <device.xml>"
    ;;
  block)
    [ $# -ge 2 ] || { echo "usage: usb-allow.sh block <id>"; exit 1; }
    usbguard block-device "$2" -p
    audit_event usb-derogation action=block id="$2" by="$_actor"
    echo "[+] Blocked + persisted device $2 (logged: by $_actor)."
    ;;
  *)
    echo "usage: usb-allow.sh [list|allow <id>|block <id>]"; exit 1 ;;
esac
