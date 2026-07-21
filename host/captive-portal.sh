#!/bin/bash
# =============================================================================
# host/captive-portal.sh
# -----------------------------------------------------------------------------
# Handle a captive-portal WiFi with interactive browser Entra/OAuth login on an
# otherwise-headless kiosk host.
#
# WHY THIS WORKS:
#   All three VMs are NAT'd out the host's single wlan0 MAC. A captive portal
#   authorizes per client MAC, so the host only needs to authenticate ONCE — via
#   a browser — and every VM is then online. The host's MAC must be stable
#   (host/wifi.sh sets mac_addr=0 for exactly this reason).
#
# WHAT THIS INSTALLS:
#   * a minimal host browser (firefox-esr), used ONLY for the portal
#   * <kiosk-home>/portal-login.sh : detects the portal and opens it in the browser
#   * an i3 keybinding (Super+p) on a scratch workspace to launch it
#
# UX: kiosk is unbroken except during the brief portal login. Press Super+p,
#   complete Entra OAuth + MFA once, close the browser, back to the VMs.
#
# BOOTSTRAP ORDER (important): the portal must be cleared BEFORE 03 (VM image
#   downloads) and guest cloud-init, which need internet on first boot:
#     firstboot: 01 -> 02 -> 06 -> 04 -> 07
#     operator : Super+p (portal login) -> ./environments/create.sh -> ./05-...
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config

# Overridable: connectivity-check URL that returns 204 when NOT behind a portal.
: "${PORTAL_PROBE_URL:=http://connectivitycheck.gstatic.com/generate_204}"
# Browser command (overridable). The image bakes firefox-esr, whose Alpine binary
# is "firefox-esr" (there is NO bare "firefox"). Prefer it, fall back to firefox.
if [ -z "${PORTAL_BROWSER:-}" ]; then
  if command -v firefox-esr >/dev/null 2>&1; then PORTAL_BROWSER=firefox-esr
  else PORTAL_BROWSER=firefox; fi
fi

# The desktop runs as the UNPRIVILEGED kiosk user; its i3 (host/switching.sh)
# reads $KIOSK_HOME/.config/i3/config and execs helpers as that user. Writing the
# binding to /root/.config/i3/config (never created) and the helper to /root
# (mode 0700, kiosk can't traverse) meant Super+p silently did nothing. Target the
# kiosk home instead.
KIOSK_USER="${KIOSK_USER:-kiosk}"
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"; KIOSK_HOME="${KIOSK_HOME:-/home/$KIOSK_USER}"
PORTAL_SH="$KIOSK_HOME/portal-login.sh"

# -----------------------------------------------------------------------------
# 1. Ensure a browser exists (idempotent). Only meaningful when using WiFi;
#    harmless otherwise.
# -----------------------------------------------------------------------------
if ! command -v "$PORTAL_BROWSER" >/dev/null 2>&1; then
  log "Installing browser for captive-portal login ..."
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache firefox-esr || apk add --no-cache firefox || \
      warn "Could not install a browser; install one manually."
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends firefox-esr || true
  fi
fi

# -----------------------------------------------------------------------------
# 2. portal-login.sh — detect the captive portal and open it.
#    Detection: hit the probe URL. If we get HTTP 204 -> already online, no-op.
#    Otherwise a portal is intercepting; open the effective (redirected) URL so
#    the browser lands straight on the Entra login.
# -----------------------------------------------------------------------------
log "Writing $PORTAL_SH ..."
cat > "$PORTAL_SH" <<EOF
#!/bin/sh
# Captive-portal login helper. Opens the portal in a browser for interactive
# Entra/OAuth sign-in. NAT means authenticating this host MAC frees all VMs.
PROBE="$PORTAL_PROBE_URL"
BROWSER="$PORTAL_BROWSER"
EOF
cat >> "$PORTAL_SH" <<'EOF'

# Are we already online (portal cleared)?
code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$PROBE" || echo 000)"
if [ "$code" = "204" ]; then
  notify_ok() { command -v i3-nagbar >/dev/null 2>&1 && \
    i3-nagbar -t warning -m "Already online — no portal login needed." & }
  notify_ok
  exit 0
fi

# Find the URL the portal redirects us to (the Entra login entry point).
portal_url="$(curl -s -o /dev/null -w '%{redirect_url}' -m 5 "$PROBE" || true)"
[ -n "$portal_url" ] || portal_url="http://neverssl.com"   # forces a redirect

# Launch the browser on the portal. User completes Entra OAuth + MFA here.
exec "$BROWSER" --new-window "$portal_url"
EOF
chmod +x "$PORTAL_SH"
chown "$KIOSK_USER:$KIOSK_USER" "$PORTAL_SH" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 3. Add the i3 keybinding (Super+p) idempotently. Uses a scratch workspace so
#    the login browser floats over the kiosk without disturbing VM workspaces.
# -----------------------------------------------------------------------------
I3_CFG="$KIOSK_HOME/.config/i3/config"
if [ -f "$I3_CFG" ]; then
  if ! grep -q 'portal-login.sh' "$I3_CFG"; then
    log "Adding Super+p captive-portal binding to i3 config ..."
    # Unquoted heredoc: i3's own vars are \$-escaped (kept literal), $PORTAL_SH
    # expands to the kiosk-reachable helper path.
    cat >> "$I3_CFG" <<EOF

# --- Captive-portal login (Entra/OAuth) -------------------------------------
# Super+p opens the portal in a browser on a floating scratch window.
# Authenticate once (NAT => all VMs get online through the host MAC).
set \$wsportal "portal"
bindsym \$mod+p workspace \$wsportal; exec --no-startup-id $PORTAL_SH
# Let the browser float and NOT be forced fullscreen like the VM viewers.
for_window [class="(?i)firefox"] floating enable, border normal
EOF
    chown "$KIOSK_USER:$KIOSK_USER" "$I3_CFG" 2>/dev/null || true
  else
    log "i3 portal binding already present."
  fi
else
  warn "i3 config not found yet — run host/switching.sh first, then re-run host/captive-portal.sh."
fi

ok "Captive-portal login configured. Press Super+p to authenticate the WiFi."
cat <<EOF

MANUAL (each session / after portal timeout):
  1. Super+p  -> browser opens the Entra portal
  2. Sign in (OAuth + MFA)
  3. Close browser; all VMs now have internet (host MAC authorized via NAT)

Bootstrap: do the portal login BEFORE ./environments/create.sh (guests need internet
for cloud-init on first boot).
EOF
