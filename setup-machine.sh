#!/bin/sh
# =============================================================================
# setup-machine.sh — the operator's remaining steps, on the INSTALLED appliance
# -----------------------------------------------------------------------------
# The HOST base (hardware detect, kiosk user, hardening, i3 switching, Wi-Fi,
# captive-portal hook) already ran AUTOMATICALLY at first boot — those steps are
# NOT repeated here. What is left for you, in order:
#
#   1) Create the VMs        2) Isolate + verify
#
# Run as root on tty2 (Ctrl+Alt+F2), from /opt/appliance.
#
#   ./setup-machine.sh          # show the menu and pick a step
#   ./setup-machine.sh <n>      # run step <n> directly (e.g. ./setup-machine.sh 1)
#   ./setup-machine.sh -h       # usage
#
# If the machine had no network at first boot, re-run src/host/wifi.sh by hand
# (and press Super+p on the desktop for a captive portal) BEFORE step 1 — the
# guests need internet on their first boot.
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

# The group dirs live under src/ in current trees; older appliances (and the
# test sandbox) have them flat next to this script. Support both.
if [ -d "$HERE/src/host" ]; then SRC="$HERE/src"; else SRC="$HERE"; fi

usage() {
  cat <<EOF
Usage:
  ./setup-machine.sh            show the menu and pick a step
  ./setup-machine.sh <n> [args] run step <n> directly (1-11, extra args forwarded)
  ./setup-machine.sh -h         this help
EOF
}

show_menu() {
  cat <<EOF

======================= Appliance setup =======================
 Host base already configured at first boot (Wi-Fi and captive
 portal included). Steps left for you:

   1) Create the VMs ........... src/environments/create.sh
   2) Isolate + verify ........ src/environments/isolate.sh

 Day-two operations:

   3) Change a VM password .... src/environments/set-guest-password.sh [env]
   4) Per-env VPN (optional) .. src/environments/vpn.sh
   5) Scrub secrets (optional)  src/environments/scrub-secrets.sh
   6) Secure Boot/TPM (opt) ... src/host/secure-boot.sh
   7) Diagnose / repair a VM .. src/environments/guest-doctor.sh [env]
   8) Compliance check ........ src/host/compliance-check.sh
   9) Update packages + SBOM .. src/host/update-packages.sh
  10) Secure erase (EOL) ...... src/host/secure-erase.sh
  11) File diode (PA-114 §3.18) src/environments/diode.sh [--list|--pair a>b]

 Locked out of a VM, or it has no desktop? Step 7 reads and
 repairs the guest's disk from the host — it needs neither a
 working password nor the guest agent. Shut the VM down first.

 First run order:  1 -> 2
 Guests need internet on first boot, so the uplink must be up
 BEFORE step 1 (first boot did it; to redo: src/host/wifi.sh,
 and Super+p on the desktop for a captive portal).
===============================================================
EOF
}

# run_step <n> [extra args...] — any extra args are passed straight to the
# underlying script, so e.g. `./setup-machine.sh 3 office` changes just that
# env's password instead of prompting for all of them.
run_step() {
  step="$1"; shift
  case "$step" in
    1) exec "$SRC/environments/create.sh" "$@" ;;
    2) exec "$SRC/environments/isolate.sh" "$@" ;;
    3) exec "$SRC/environments/set-guest-password.sh" "$@" ;;
    4) exec "$SRC/environments/vpn.sh" "$@" ;;
    5) exec "$SRC/environments/scrub-secrets.sh" "$@" ;;
    6) exec "$SRC/host/secure-boot.sh" "$@" ;;
    7) exec "$SRC/environments/guest-doctor.sh" "$@" ;;
    8) exec "$SRC/host/compliance-check.sh" "$@" ;;
    9) exec "$SRC/host/update-packages.sh" "$@" ;;
    10) exec "$SRC/host/secure-erase.sh" "$@" ;;
    11) exec "$SRC/environments/diode.sh" "$@" ;;
    q|Q) exit 0 ;;
    *) echo "Unknown step: $step" >&2; exit 1 ;;
  esac
}

# Dispatch. Direct mode (`./setup-machine.sh <n> [args...]`) lets scripts and
# tests drive a step unattended; with NO arguments the operator gets the menu.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "")        ;;
  *)         run_step "$@" ;;
esac

# Interactive menu. The line is word-split on purpose so "3 office" works here
# exactly like `./setup-machine.sh 3 office` does.
show_menu
printf 'Step to run [1-11, q to quit]: '
read -r choice || exit 0
[ -n "$choice" ] || exit 0
# shellcheck disable=SC2086  # intentional word split: "<step> [args...]"
run_step $choice
