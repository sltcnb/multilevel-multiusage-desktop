#!/bin/bash
# =============================================================================
# host/configure.sh
# -----------------------------------------------------------------------------
# Configure the booted host so it: autologins root on tty1, auto-starts X, and
# X launches i3 (the VM viewers are launched by i3, see 04). Also disables
# guest-bridging channels (defense-in-depth for isolation).
#
# NOTE ON "install onto disk":
#   The canonical Alpine way to commit a running ISO session to disk is the
#   interactive `setup-alpine` + `setup-disk`. That step is INHERENTLY MANUAL
#   (it asks for keyboard/timezone/target disk) and is destructive, so this
#   script does NOT run it silently. See the MANUAL block below. Everything
#   this script writes lives in the root filesystem, so after `setup-disk`
#   copies the running system to disk, these configs come along.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config
require_cmds startx i3 || true   # present after 01; warn-only if minimal.

# -----------------------------------------------------------------------------
# 1. Autologin root on tty1.
#    Alpine uses agetty via /etc/inittab. We rewrite the tty1 line to autologin.
# -----------------------------------------------------------------------------
# Unprivileged kiosk user (ANSSI: desktop must not run as root). Create if missing
# and give it ONLY VM view/launch rights (libvirt/kvm) — no sudo, no root powers.
KIOSK_USER="${KIOSK_USER:-kiosk}"
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  log "Creating unprivileged kiosk user '$KIOSK_USER' ..."
  adduser -D -s /bin/bash "$KIOSK_USER" 2>/dev/null || useradd -m -s /bin/bash "$KIOSK_USER" 2>/dev/null || true
fi
for g in libvirt libvirtd kvm video input; do addgroup "$KIOSK_USER" "$g" 2>/dev/null || usermod -aG "$g" "$KIOSK_USER" 2>/dev/null || true; done
passwd -u "$KIOSK_USER" 2>/dev/null || true
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"; KIOSK_HOME="${KIOSK_HOME:-/home/$KIOSK_USER}"

# Root password for admin on tty2 — from config (HOST_ROOT_PASSWORD). Empty or
# "generate" => a strong one is generated + recorded in /root/generated-secrets.txt.
ROOT_PW="$(resolve_secret HOST_ROOT_PASSWORD)"
echo "root:$ROOT_PW" | chpasswd 2>/dev/null && log "Root password set (admin on tty2)." || warn "Failed to set root password."

# Let libvirt-group members (the unprivileged kiosk user) use qemu:///system so
# virt-viewer can connect + the VMs can be viewed without root or a polkit prompt.
if [ -f /etc/libvirt/libvirtd.conf ]; then
  sed -i 's/^#*unix_sock_group.*/unix_sock_group = "libvirt"/'      /etc/libvirt/libvirtd.conf
  sed -i 's/^#*unix_sock_rw_perms.*/unix_sock_rw_perms = "0770"/'   /etc/libvirt/libvirtd.conf
  sed -i 's/^#*auth_unix_rw.*/auth_unix_rw = "none"/'               /etc/libvirt/libvirtd.conf
  rc-service libvirtd restart 2>/dev/null || true
fi

AUTOLOGIN_USER="$KIOSK_USER"
if [ -f /etc/inittab ]; then
  log "Configuring tty1 autologin ($AUTOLOGIN_USER) in /etc/inittab ..."
  # Replace the tty1 getty line. busybox getty supports -n -l for autologin.
  # Backup once.
  [ -f /etc/inittab.orig ] || cp /etc/inittab /etc/inittab.orig
  # Remove existing tty1 line(s), append our autologin line.
  grep -v '^tty1::' /etc/inittab > /etc/inittab.tmp
  echo "tty1::respawn:/sbin/agetty --autologin $AUTOLOGIN_USER --noclear tty1 linux" >> /etc/inittab.tmp
  mv /etc/inittab.tmp /etc/inittab
elif command -v systemctl >/dev/null 2>&1; then
  # Debian/systemd alternative: getty override drop-in.
  log "Configuring systemd getty autologin ($AUTOLOGIN_USER) ..."
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $AUTOLOGIN_USER --noclear %I \$TERM
EOF
  systemctl daemon-reload || true
fi

# -----------------------------------------------------------------------------
# 2. Auto-startx from .bash_profile — ONLY on tty1, ONLY if X not running.
#    Guards prevent an X loop when you SSH in or switch VTs.
# -----------------------------------------------------------------------------
HOME_DIR="$KIOSK_HOME"     # kiosk user's home, not /root
# Alpine's login shell reads ~/.profile. Write it so auto-startx fires for kiosk.
log "Writing $HOME_DIR/.profile (auto-startx on tty1) ..."
cat > "$HOME_DIR/.profile" <<'EOF'
# Kiosk drives the SYSTEM libvirt instance (where the VMs live), not the per-user
# session — virsh + virt-viewer default here.
export LIBVIRT_DEFAULT_URI=qemu:///system
# Auto-start X on the first console only.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
EOF

# -----------------------------------------------------------------------------
# 3. .xinitrc — start i3. i3 (via 04's config) spawns the three virt-viewers.
#    Kept minimal: no compositor, software rendering (no GPU passthrough yet).
# -----------------------------------------------------------------------------
log "Writing $HOME_DIR/.xinitrc ..."
cat > "$HOME_DIR/.xinitrc" <<'EOF'
#!/bin/sh
# Blank/disable screen power management annoyances on an appliance.
xset s off -dpms || true
xset r rate 250 40 || true
# Single keyboard/mouse; adjust layout here if not US.
setxkbmap us || true
# TODO(GPU-passthrough): when moving to VFIO GPU passthrough, the viewer for
# the passed-through VM will render on the real GPU output instead of SPICE.
# At that point you may drop that VM's virt-viewer here and let the guest own
# the physical display. Leave SPICE viewers for the remaining VMs.
exec i3
EOF
# Apply the configured keyboard layout (config KEYBOARD_LAYOUT, e.g. us, fr,
# de, or "fr:oss" for layout:variant). Replaces the default 'setxkbmap us'.
KB="${KEYBOARD_LAYOUT:-us}"
if echo "$KB" | grep -q ':'; then
  kbcmd="setxkbmap ${KB%%:*} -variant ${KB#*:}"
else
  kbcmd="setxkbmap $KB"
fi
sed -i "s|setxkbmap us|$kbcmd|" "$HOME_DIR/.xinitrc"
log "Keyboard layout: $KB"
chmod +x "$HOME_DIR/.xinitrc"
chown "$KIOSK_USER:$KIOSK_USER" "$HOME_DIR/.profile" "$HOME_DIR/.xinitrc" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. Disable guest-bridging channels (isolation hardening).
#    - No shared 9p/virtiofs mounts are created (we simply never define them; 03
#      creates no <filesystem> devices).
#    - Ensure libvirt's default NAT network (a SHARED bridge) is gone so guests
#      can't accidentally land on a common segment. 05 creates per-VM nets.
# -----------------------------------------------------------------------------
if command -v virsh >/dev/null 2>&1; then
  if virsh net-info default >/dev/null 2>&1; then
    log "Removing libvirt 'default' shared network (isolation) ..."
    virsh net-destroy default 2>/dev/null || true
    virsh net-autostart default --disable 2>/dev/null || true
    virsh net-undefine default 2>/dev/null || true
  fi
fi
# The SPICE agent (spice-vdagent) provides clipboard/folder sharing INSIDE a
# guest between that guest and its viewer — it does NOT bridge guests together,
# so it is safe. We deliberately do NOT install any cross-VM clipboard daemon.

# -----------------------------------------------------------------------------
# ANSSI peripheral compartmentalization (#9). Default-DENY USB (USBGUARD=1 by
# default): a device is never silently shared across environments. Input devices
# (keyboards/mice, interface class 03) and hubs (class 09) are ALWAYS allowed so
# the machine stays usable; everything else (mass storage, etc.) is BLOCKED until
# explicitly whitelisted with the `usb-allow` tool. To hand a whitelisted device
# to one VM only: `virsh attach-device <env> ...`.
# -----------------------------------------------------------------------------
if [ "${USBGUARD:-1}" = "1" ] && command -v usbguard >/dev/null 2>&1; then
  log "Enabling usbguard: default-deny USB, allow input devices + hubs ..."
  mkdir -p /etc/usbguard
  # Daemon: implicitly BLOCK anything not matched by a rule; apply to present +
  # future devices; keep the controller.
  cat > /etc/usbguard/usbguard-daemon.conf <<'DCONF'
RuleFile=/etc/usbguard/rules.conf
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=false
IPCAllowedUsers=root
DCONF
  # Rules: allow HID (input) + hubs; block the rest (implicit). The whitelist
  # tool appends `allow` lines for specific data devices below these.
  cat > /etc/usbguard/rules.conf <<'RCONF'
# --- always-allowed: human input devices + hubs (keep the machine usable) ---
allow with-interface one-of { 03:*:* }
allow with-interface equals { 09:00:00 }
# --- whitelist (managed by host/usb-allow.sh) appends `allow id ...` below ---
RCONF
  chmod 600 /etc/usbguard/rules.conf /etc/usbguard/usbguard-daemon.conf 2>/dev/null || true
  rc-update add usbguard default 2>/dev/null || true
  rc-service usbguard restart 2>/dev/null || rc-service usbguard start 2>/dev/null || true
  ok "usbguard active. Whitelist a data device with: host/usb-allow.sh"
else
  [ "${USBGUARD:-1}" = "1" ] && warn "USBGUARD=1 but usbguard not installed."
fi

# -----------------------------------------------------------------------------
# YubiKey -> choose-a-VM routing (YUBIKEY_ROUTER=1). On plug you pick which env
# gets the key; host/usb-to-vm.sh USB-passes it to ONLY that VM (never shared).
#   * usbguard: allow Yubico (vendor 1050) so the device isn't blocked at plug.
#   * udev: on insert, pop the chooser (root xterm) on the kiosk X display.
# Also bound to Super+y in i3/keyd (host/switching.sh) as a manual fallback.
# -----------------------------------------------------------------------------
if [ "${YUBIKEY_ROUTER:-1}" = "1" ]; then
  log "Enabling YubiKey->VM router (usbguard allow Yubico + udev auto-chooser) ..."
  # Let usbguard admit the YubiKey (otherwise default-deny blocks it pre-passthrough).
  if [ -f /etc/usbguard/rules.conf ] && ! grep -q '1050' /etc/usbguard/rules.conf; then
    printf 'allow id 1050:*\n' >> /etc/usbguard/rules.conf
    rc-service usbguard restart 2>/dev/null || true
  fi
  # udev: on Yubico add, launch the chooser as ROOT on the kiosk display. setsid
  # detaches it from the short-lived udev worker so it survives. Root can reach
  # the kiosk X session via its XAUTHORITY.
  APP_DIR="$HERE/.."; APP_DIR="$(cd "$APP_DIR" && pwd)"
  cat > /usr/local/bin/yubikey-plugged <<EOF
#!/bin/sh
export DISPLAY=:0
export XAUTHORITY="$KIOSK_HOME/.Xauthority"
setsid xterm -geometry 60x18 -T "Route YubiKey" -e "$APP_DIR/host/usb-to-vm.sh" >/dev/null 2>&1 &
EOF
  chmod +x /usr/local/bin/yubikey-plugged
  mkdir -p /etc/udev/rules.d
  cat > /etc/udev/rules.d/99-yubikey-router.rules <<'URULE'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1050", RUN+="/usr/local/bin/yubikey-plugged"
URULE
  udevadm control --reload 2>/dev/null || true
  ok "YubiKey router active (auto-chooser on plug; Super+y = manual chooser)."
fi

ok "Host configured."
cat <<EOF

MANUAL STEP (destructive, interactive) — commit host to disk:
  On Alpine ISO session, run:
      setup-alpine        # keyboard, hostname, network, disk
      # choose 'sys' install mode to write to the target disk
  Then reboot from disk.  The .bash_profile/.xinitrc/inittab written here are
  in the root fs and will persist. Re-run 01 on first disk boot if you used a
  fresh disk that did not copy the apk packages.

Debian alternative: use the netinst 'expert' or preseed; autologin drop-in
already written above.

Next: ./environments/create.sh
EOF
