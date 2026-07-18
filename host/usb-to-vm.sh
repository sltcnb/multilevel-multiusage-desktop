#!/bin/bash
# =============================================================================
# host/usb-to-vm.sh — route a plugged YubiKey (or any USB device) to ONE VM
# -----------------------------------------------------------------------------
# On plug you choose which environment gets the device; it is USB-passed-through
# to exactly that VM and detached from any other (never shared across envs —
# ANSSI peripheral compartmentalization). Runs as root (needs virsh + system VMs).
#
# Triggered automatically on YubiKey insert (udev rule installed by configure.sh),
# or manually: `host/usb-to-vm.sh`  (optionally `host/usb-to-vm.sh <vendor:product>`).
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# No require_root: the kiosk user is in the libvirt group and uses qemu:///system,
# so `virsh attach-device` works unprivileged. The udev path runs this as root,
# which also works. Either way we only touch libvirt, never usbguard IPC.
load_config
export LIBVIRT_DEFAULT_URI=qemu:///system

# --- identify the device (arg vendor:product, else the plugged YubiKey) -------
vp="${1:-}"
if [ -z "$vp" ]; then
  vp="$(lsusb 2>/dev/null | grep -iE '1050:|Yubico' | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' | head -1 || true)"
fi
[ -n "$vp" ] || { echo "No YubiKey detected (plug it in first, or pass vendor:product)."; sleep 3; exit 1; }
vend="${vp%:*}"; prod="${vp#*:}"

# --- choose the target environment -------------------------------------------
envs="$(for_each_enabled_env | awk '{print $1}')"
echo; echo "Send USB device $vp to which environment?"
i=0; for e in $envs; do i=$((i+1)); printf '  %s) %s\n' "$i" "$e"; done
printf 'choice [1-%s] (or q): ' "$i"; read -r c
[ "$c" = "q" ] && exit 0
target="$(echo "$envs" | awk -v n="$c" '{print $n}')"
[ -n "$target" ] || { echo "invalid choice"; sleep 2; exit 1; }

hostdev() { printf "<hostdev mode='subsystem' type='usb'><source><vendor id='0x%s'/><product id='0x%s'/></source></hostdev>" "$vend" "$prod"; }

# --- detach from every other env first, then attach to the chosen one ---------
for e in $envs; do
  [ "$e" = "$target" ] && continue
  hostdev | virsh detach-device "$e" /dev/stdin --live 2>/dev/null || true
done
if hostdev | virsh attach-device "$target" /dev/stdin --live; then
  echo "YubiKey $vp -> $target"
else
  echo "Attach failed (is $target running?)"; sleep 3; exit 1
fi
sleep 1
