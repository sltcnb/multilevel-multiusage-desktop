#!/bin/sh
# =============================================================================
# setup.sh — numbered operator menu for the appliance
# -----------------------------------------------------------------------------
# The HOST base (hardware detect, kiosk user, hardening, i3 switching, Wi-Fi if
# configured) already ran AUTOMATICALLY at first boot. These are the steps YOU
# launch, in order. Run as root on tty2 (Ctrl+Alt+F2), from /opt/appliance.
#
#   ./setup.sh          # interactive numbered menu
#   ./setup.sh <n>      # run step <n> directly (e.g. ./setup.sh 3)
#
# Typical first run:  1 (only if on Wi-Fi)  ->  Super+p (only if captive portal)
#                     ->  3  ->  4
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

show_menu() {
  cat <<EOF

======================= Appliance setup =======================
 Host base already configured at first boot. Steps you launch:

   1) Wi-Fi uplink ............. host/wifi.sh         (skip if wired)
   2) Captive-portal login ..... press Super+p on the desktop  (Entra/OAuth)
   3) Create the VMs ........... environments/create.sh
   4) Isolate + verify ........ environments/isolate.sh
   5) Change a VM password .... environments/set-guest-password.sh
   6) Per-env VPN (optional) .. environments/vpn.sh
   7) Scrub secrets (optional)  environments/scrub-secrets.sh
   8) Secure Boot/TPM (opt) ... host/secure-boot.sh

 First run order:  1 (Wi-Fi) -> Super+p (portal) -> 3 -> 4
 Guests need internet on first boot, so clear Wi-Fi/portal BEFORE step 3.
===============================================================
EOF
}

run_step() {
  case "$1" in
    1) exec "$HERE/host/wifi.sh" ;;
    2) echo "Press Super+p on the desktop to open the captive portal (Entra/OAuth)."
       echo "Sign in once; NAT then puts every VM online. Nothing to run here." ;;
    3) exec "$HERE/environments/create.sh" ;;
    4) exec "$HERE/environments/isolate.sh" ;;
    5) exec "$HERE/environments/set-guest-password.sh" ;;
    6) exec "$HERE/environments/vpn.sh" ;;
    7) exec "$HERE/environments/scrub-secrets.sh" ;;
    8) exec "$HERE/host/secure-boot.sh" ;;
    q|Q) exit 0 ;;
    *) echo "Unknown step: $1" >&2; exit 1 ;;
  esac
}

# Direct mode: ./setup.sh <n>
[ $# -ge 1 ] && run_step "$1"

# Interactive menu.
show_menu
printf 'Step to run [1-8, q to quit]: '
read -r choice
run_step "$choice"
