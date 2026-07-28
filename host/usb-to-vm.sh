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
export LIBVIRT_DEFAULT_URI=qemu:///system
require_cmds virsh

# config.env is mode 0600 (it holds the guest/root passwords, the Wi-Fi PSK and
# the LUKS keys), so the kiosk user — who is exactly who presses Super+y —
# cannot read it. Sourcing it unconditionally made this script die before it
# ever drew the chooser. The env list is the only thing needed here, and libvirt
# already knows it: fall back to the defined domains when the config is out of
# reach. Root (the udev auto-chooser path) still gets the authoritative order.
if [ -r "$CONFIG_ENV" ]; then
  load_config
  envs="$(for_each_enabled_env | awk '{print $1}')"
else
  envs="$(virsh list --all --name 2>/dev/null | sed '/^$/d')"
fi
[ -n "$envs" ] || { echo "No environments found (no readable config.env and no libvirt domains)."; sleep 3; exit 1; }

# --- identify the device (arg vendor:product, else the plugged YubiKey) -------
vp="${1:-}"
if [ -z "$vp" ]; then
  vp="$(lsusb 2>/dev/null | grep -iE '1050:|Yubico' | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' | head -1 || true)"
fi
[ -n "$vp" ] || { echo "No YubiKey detected (plug it in first, or pass vendor:product)."; sleep 3; exit 1; }
vend="${vp%:*}"; prod="${vp#*:}"

# --- choose the target environment -------------------------------------------
echo; echo "Send USB device $vp to which environment?"
i=0; for e in $envs; do i=$((i+1)); printf '  %s) %s\n' "$i" "$e"; done
printf 'choice [1-%s] (or q): ' "$i"; read -r c
[ "$c" = "q" ] && exit 0
# Validate BEFORE using $c as an awk field index: an empty/non-numeric choice
# coerces to 0, so `$n` prints $0 (the whole env list) — a non-empty string that
# slips past the guard below and detaches the device from every env, attaching to
# none. Reject anything that is not a decimal in 1..$i.
case "$c" in ''|*[!0-9]*) echo "invalid choice"; sleep 2; exit 1 ;; esac
{ [ "$c" -ge 1 ] && [ "$c" -le "$i" ]; } || { echo "invalid choice"; sleep 2; exit 1; }
# $envs is one environment per LINE, so the choice selects a line — not a field.
# `awk '{print $n}'` printed field n of every line, which is empty for every
# n > 1: picking anything but the first environment always failed with "invalid
# choice", making the chooser useless for the 2nd and 3rd VMs.
target="$(printf '%s\n' "$envs" | sed -n "${c}p")"
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
