#!/bin/sh
# =============================================================================
# setup.sh — step 3 of 3: the operator's remaining steps, on the INSTALLED box
# -----------------------------------------------------------------------------
# The LAST of three endpoints (./configure.sh wrote config.env, ./flash.sh built
# and flashed the stick; this script runs ON the appliance). The HOST base
# (hardware detect, kiosk user, hardening, i3 switching, Wi-Fi, captive-portal
# hook) already ran AUTOMATICALLY at first boot — those steps are NOT repeated
# here. What is left for you, in order:
#
#   1) Create the VMs        2) Isolate + verify
#
# Run as root on tty2 (Ctrl+Alt+F2), from /opt/appliance.
#
#   ./setup.sh          # show the menu and pick a step
#   ./setup.sh <n>      # run step <n> directly (e.g. ./setup.sh 1)
#   ./setup.sh -h       # usage
#
# If the machine had no network at first boot, re-run host.sh wifi by hand
# (and press Super+p on the desktop for a captive portal) BEFORE step 1 — the
# guests need internet on their first boot.
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

# The dispatchers live under src/ in current trees; older appliances (and the
# test sandbox) may keep them flat next to this script. Support both.
if [ -f "$HERE/src/host.sh" ]; then SRC="$HERE/src"; else SRC="$HERE"; fi

usage() {
  cat <<EOF
Usage:
  ./setup.sh            show the menu and pick a step
  ./setup.sh <n> [args] run step <n> directly (1-11, extra args forwarded)
  ./setup.sh -h         this help
EOF
}

show_menu() {
  cat <<EOF

======================= Appliance setup =======================
 Host base already configured at first boot (Wi-Fi and captive
 portal included). Steps left for you:

   1) Create the VMs ........... environments.sh create
   2) Isolate + verify ........ environments.sh isolate

 Day-two operations:

   3) Change a VM password .... environments.sh set-guest-password [env]
   4) Per-env VPN (optional) .. environments.sh vpn
   5) Scrub secrets (optional)  environments.sh scrub-secrets
   6) Secure Boot/TPM (opt) ... host.sh secure-boot
   7) Diagnose / repair a VM .. environments.sh guest-doctor [env]
   8) Compliance check ........ host.sh compliance-check
   9) Update packages + SBOM .. host.sh update-packages
  10) Secure erase (EOL) ...... host.sh secure-erase
  11) File diode (PA-114 §3.18) environments.sh diode [--list|--pair a>b]

 Locked out of a VM, or it has no desktop? Step 7 reads and
 repairs the guest's disk from the host — it needs neither a
 working password nor the guest agent. Shut the VM down first.

 First run order:  1 -> 2
 Guests need internet on first boot, so the uplink must be up
 BEFORE step 1 (first boot did it; to redo: host.sh wifi,
 and Super+p on the desktop for a captive portal).
===============================================================
EOF
}

# run_step <n> [extra args...] — any extra args are passed straight to the
# underlying script, so e.g. `./setup.sh 3 office` changes just that
# env's password instead of prompting for all of them.
run_step() {
  step="$1"; shift
  case "$step" in
    1) exec "$SRC/environments.sh" create "$@" ;;
    2) exec "$SRC/environments.sh" isolate "$@" ;;
    3) exec "$SRC/environments.sh" set-guest-password "$@" ;;
    4) exec "$SRC/environments.sh" vpn "$@" ;;
    5) exec "$SRC/environments.sh" scrub-secrets "$@" ;;
    6) exec "$SRC/host.sh" secure-boot "$@" ;;
    7) exec "$SRC/environments.sh" guest-doctor "$@" ;;
    8) exec "$SRC/host.sh" compliance-check "$@" ;;
    9) exec "$SRC/host.sh" update-packages "$@" ;;
    10) exec "$SRC/host.sh" secure-erase "$@" ;;
    11) exec "$SRC/environments.sh" diode "$@" ;;
    q|Q) exit 0 ;;
    *) echo "Unknown step: $step" >&2; exit 1 ;;
  esac
}

# Dispatch. Direct mode (`./setup.sh <n> [args...]`) lets scripts and
# tests drive a step unattended; with NO arguments the operator gets the menu.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "")        ;;
  *)         run_step "$@" ;;
esac

# Interactive menu. The line is word-split on purpose so "3 office" works here
# exactly like `./setup.sh 3 office` does.
show_menu
printf 'Step to run [1-11, q to quit]: '
read -r choice || exit 0
[ -n "$choice" ] || exit 0
# shellcheck disable=SC2086  # intentional word split: "<step> [args...]"
run_step $choice
