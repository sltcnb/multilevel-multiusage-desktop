#!/bin/sh
# =============================================================================
# setup-machine.sh — entry point for the operator, on the INSTALLED appliance
# -----------------------------------------------------------------------------
# The HOST base (hardware detect, kiosk user, hardening, i3 switching, Wi-Fi if
# configured) already ran AUTOMATICALLY at first boot. These are the steps YOU
# launch, in order. Run as root on tty2 (Ctrl+Alt+F2), from /opt/appliance.
#
#   ./setup-machine.sh          # the operator console (src/host/tui.sh):
#                               # dashboard, guided first setup, operations menu
#   ./setup-machine.sh --menu   # the classic numbered text menu (below)
#   ./setup-machine.sh <n>      # run step <n> directly (e.g. ./setup-machine.sh 3)
#   ./setup-machine.sh -h       # usage
#
# Typical first run:  1 (only if on Wi-Fi)  ->  Super+p (only if captive portal)
#                     ->  3  ->  4
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

# The group dirs live under src/ in current trees; older appliances (and the
# test sandbox) have them flat next to this script. Support both.
if [ -d "$HERE/src/host" ]; then SRC="$HERE/src"; else SRC="$HERE"; fi

usage() {
  cat <<EOF
Usage:
  ./setup-machine.sh            launch the operator console (src/host/tui.sh)
  ./setup-machine.sh --menu     the classic numbered text menu
  ./setup-machine.sh <n> [args] run step <n> directly (1-8, extra args forwarded)
  ./setup-machine.sh -h         this help
EOF
}

show_menu() {
  cat <<EOF

======================= Appliance setup =======================
 Host base already configured at first boot. Steps you launch:

   1) Wi-Fi uplink ............. src/host/wifi.sh         (skip if wired)
   2) Captive-portal login ..... press Super+p on the desktop  (Entra/OAuth)
   3) Create the VMs ........... src/environments/create.sh
   4) Isolate + verify ........ src/environments/isolate.sh
   5) Change a VM password .... src/environments/set-guest-password.sh [env]
   6) Per-env VPN (optional) .. src/environments/vpn.sh
   7) Scrub secrets (optional)  src/environments/scrub-secrets.sh
   8) Secure Boot/TPM (opt) ... src/host/secure-boot.sh

 First run order:  1 (Wi-Fi) -> Super+p (portal) -> 3 -> 4
 Guests need internet on first boot, so clear Wi-Fi/portal BEFORE step 3.
===============================================================
EOF
}

# run_step <n> [extra args...] — any extra args are passed straight to the
# underlying script, so e.g. `./setup-machine.sh 5 office` changes just that
# env's password instead of prompting for all of them.
run_step() {
  step="$1"; shift
  case "$step" in
    1) exec "$SRC/host/wifi.sh" "$@" ;;
    2) echo "Press Super+p on the desktop to open the captive portal (Entra/OAuth)."
       echo "Sign in once; NAT then puts every VM online. Nothing to run here." ;;
    3) exec "$SRC/environments/create.sh" "$@" ;;
    4) exec "$SRC/environments/isolate.sh" "$@" ;;
    5) exec "$SRC/environments/set-guest-password.sh" "$@" ;;
    6) exec "$SRC/environments/vpn.sh" "$@" ;;
    7) exec "$SRC/environments/scrub-secrets.sh" "$@" ;;
    8) exec "$SRC/host/secure-boot.sh" "$@" ;;
    q|Q) exit 0 ;;
    *) echo "Unknown step: $step" >&2; exit 1 ;;
  esac
}

# Dispatch. Direct mode (`./setup-machine.sh <n> [args...]`) is byte-for-byte
# the old behaviour — scripts and tests drive it unattended. With NO arguments
# the operator gets the full-screen console; the old numbered menu stays one
# flag away for minimal terminals and muscle memory.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --menu)    shift ;;
  "")        exec "$SRC/host/tui.sh" ;;
  *)         run_step "$@" ;;
esac

# --menu: the classic interactive numbered menu. The line is word-split on
# purpose so "5 office" works here exactly like `./setup-machine.sh 5 office`
# does.
show_menu
printf 'Step to run [1-8, q to quit]: '
read -r choice || exit 0
[ -n "$choice" ] || exit 0
# shellcheck disable=SC2086  # intentional word split: "<step> [args...]"
run_step $choice
