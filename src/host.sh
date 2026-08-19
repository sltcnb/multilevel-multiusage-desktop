#!/bin/bash
# =============================================================================
# src/host.sh — all host-side (appliance) operations, one dispatcher.
# -----------------------------------------------------------------------------
# Merged from the former src/host/*.sh and src/host.sh install-to-disk.
#   src/host.sh <command> [args...]
# Commands:
#   detect-and-install  configure  harden  switching  wifi  captive-portal
#   install-to-disk  isolation-watch  usb-to-vm  usb-allow  secure-boot
#   tpm-initramfs-hook  compliance-check  update  update-packages  secure-erase
# bash because several commands need it; bash is installed on the appliance and
# the build host alike. Each command's body is its former standalone script,
# verbatim down to its own `set -e...`; only the shebang is dropped and the
# `../lib/*.sh` sources are pointed at the merged src/lib.sh (re-sourcing it is
# idempotent). Each command exits on its own.
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

_host_usage() {
  cat >&2 <<'U'
Usage: src/host.sh <command> [args...]
  detect-and-install   probe hardware, size VMs, stage host config
  configure            commit host/kiosk/desktop config to disk
  harden               apply the ANSSI hardening baseline
  switching            generate the i3/polybar VM-switching desktop
  wifi                 bring up the host Wi-Fi uplink
  captive-portal       install the Super+p captive-portal helper
  install-to-disk      clone the running USB image onto the internal disk
  isolation-watch      recurring isolation check ([--once]|--install-timer)
  usb-to-vm            route a plugged USB device to ONE VM
  usb-allow            whitelist/block a USB device past usbguard
  secure-boot          Secure Boot + measured boot + TPM binding
  tpm-initramfs-hook   TPM auto-unlock of the LUKS root
  compliance-check     post-install conformity gate
  update               in-place update of the appliance CODE
  update-packages      upgrade host + guests, write an SBOM
  secure-erase         secure erasure / end-of-life decommission
U
}

_cmd="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$_cmd" in
detect-and-install)
# =============================================================================
# host/detect-and-install.sh
# -----------------------------------------------------------------------------
# Detect hardware, seed config.env, and produce a minimal Alpine KVM host that
# contains: kernel + KVM modules, qemu-kvm, libvirt, virt-viewer, minimal Xorg,
# and i3. Nested virtualization is DISABLED (T-14): desktop guests never need it.
#
# Two build modes:
#   * ISO / running-Alpine mode (default, most reliable): run this ON a booted
#     minimal Alpine (from the standard Alpine ISO). It installs every package
#     and stages configs, then host/configure.sh commits to disk via
#     `setup-alpine`/`setup-disk`. This is the documented Alpine way and avoids
#     brittle cross-build image plumbing.
#   * Notes for producing a flashable image are in the README (mkimage / an
#     apk-based rootfs tar). Kept as instructions because a truly flashable
#     image is host-arch specific and best done with Alpine's aports/mkimage.
#
# First-boot order (automatic): detect-and-install -> configure -> harden ->
# switching -> wifi -> captive-portal. Operator then runs ./setup.sh. See README.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_root

# -----------------------------------------------------------------------------
# 0. Seed config.env from the example if it does not exist yet (idempotent).
# -----------------------------------------------------------------------------
if [ ! -f "$CONFIG_ENV" ]; then
  log "Creating config.env from template."
  cp "$CONFIG_EXAMPLE" "$CONFIG_ENV"
fi
# shellcheck disable=SC1090
. "$CONFIG_ENV"

# -----------------------------------------------------------------------------
# 1. Detect the package manager. Alpine = apk. Note Debian alternative.
# -----------------------------------------------------------------------------
if command -v apk >/dev/null 2>&1; then
  PKG="apk"
elif command -v apt-get >/dev/null 2>&1; then
  PKG="apt"           # Debian-minimal alternative path.
  warn "apt detected: running the Debian-minimal alternative, not Alpine."
else
  die "No supported package manager (apk/apt) found."
fi
set_kv PKG "$PKG"

# -----------------------------------------------------------------------------
# 2. Detect CPU vendor -> pick KVM module + nested-virt parameter.
#    NEVER hardcoded; read straight from /proc/cpuinfo.
# -----------------------------------------------------------------------------
if grep -qi 'GenuineIntel' /proc/cpuinfo; then
  CPU_VENDOR="intel"
  KVM_MODULE="kvm_intel"
  # Nested virt DISABLED (T-14 / SO-1, SO-3): the guests are desktop VMs and have
  # no need to run their own hypervisors; leaving nested on only widens the
  # emulated surface a compromised guest can attack to break out to the host.
  NESTED_PARAM="options kvm_intel nested=0"
elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  CPU_VENDOR="amd"
  KVM_MODULE="kvm_amd"
  NESTED_PARAM="options kvm_amd nested=0"
else
  die "Unknown CPU vendor; cannot select KVM module."
fi
# Sanity: hardware virt flag present?
grep -Eq '(vmx|svm)' /proc/cpuinfo || \
  warn "No vmx/svm flag in /proc/cpuinfo — enable VT-x/AMD-V in firmware (MANUAL)."

set_kv CPU_VENDOR "$CPU_VENDOR"
set_kv KVM_MODULE "$KVM_MODULE"

# -----------------------------------------------------------------------------
# 3. Detect RAM + cores.
# -----------------------------------------------------------------------------
TOTAL_CORES="$(nproc)"
TOTAL_RAM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
set_kv TOTAL_CORES "$TOTAL_CORES"
set_kv TOTAL_RAM_MB "$TOTAL_RAM_MB"

# -----------------------------------------------------------------------------
# 4. Detect target disk / image path + free space.
# -----------------------------------------------------------------------------
mkdir -p "$IMAGES_DIR"
# Free space in MB on the filesystem that holds IMAGES_DIR.
DISK_FREE_MB="$(df -Pm "$IMAGES_DIR" | awk 'NR==2 {print $4}')"
set_kv IMAGES_DIR "$IMAGES_DIR"
set_kv DISK_FREE_MB "$DISK_FREE_MB"
if [ "$DISK_FREE_MB" -lt "$DISK_LOW_WATERMARK_MB" ]; then
  warn "Low disk: ${DISK_FREE_MB}MB free on $IMAGES_DIR (< ${DISK_LOW_WATERMARK_MB}MB)."
fi

# -----------------------------------------------------------------------------
# 5. Compute per-ENV vCPU/RAM/disk split. OVERRIDABLE FUNCTION — edit freely.
#    Splits host resources EVENLY across the ENABLED environments (see $ENVS in
#    config.env). NEVER fatal: on tight hardware we clamp to minimums and warn
#    (virt-install may oversubscribe, which is visible/fixable) rather than
#    wedging the boot. Writes ${env}_RAM_MB / ${env}_VCPU / ${env}_DISK_GB.
# -----------------------------------------------------------------------------
compute_split() {
  n="$(for_each_enabled_env | wc -l | tr -d ' ')"; [ "$n" -ge 1 ] || n=1

  avail_ram=$(( TOTAL_RAM_MB - HOST_RESERVE_RAM_MB ))
  avail_cores=$(( TOTAL_CORES - HOST_RESERVE_CORES ))
  [ "$avail_ram" -lt 1024 ]  && { warn "Low RAM after reserve (${avail_ram}MB); clamping."; avail_ram=1024; }
  [ "$avail_cores" -lt 1 ]   && { warn "Few cores after reserve; clamping to 1."; avail_cores=1; }

  per_ram=$(( avail_ram / n ));   [ "$per_ram" -ge 1024 ] || per_ram=1024
  per_cpu=$(( avail_cores / n )); [ "$per_cpu" -ge 1 ]    || per_cpu=1

  if [ "${AUTO_DISK:-1}" = "1" ]; then
    avail_disk_gb=$(( (DISK_FREE_MB - HOST_RESERVE_DISK_MB) / 1024 )); [ "$avail_disk_gb" -lt 1 ] && avail_disk_gb=1
    per_disk=$(( avail_disk_gb / n )); [ "$per_disk" -ge 8 ] || per_disk=8
  else
    per_disk="${FIXED_DISK_GB:-30}"
  fi

  log "Per-env split across $n enabled env(s): RAM=${per_ram}MB VCPU=${per_cpu} DISK=${per_disk}G"
  # set_kv writes to config.env (persists even from this pipe subshell).
  for_each_enabled_env | while read -r e _; do
    set_kv "${e}_RAM_MB"  "$per_ram"
    set_kv "${e}_VCPU"    "$per_cpu"
    set_kv "${e}_DISK_GB" "$per_disk"
  done
}
compute_split

# -----------------------------------------------------------------------------
# 6. Install host packages.
#    On the PREBUILT IMAGE everything is already installed. Re-running apk at
#    first boot would need network (and hang if none is up yet). So skip the
#    package step entirely when the core tools are already present — this makes
#    first boot fast and network-independent. Force with FORCE_PKG_INSTALL=1.
# -----------------------------------------------------------------------------
already_provisioned=1
for c in qemu-system-x86_64 virsh virt-install i3 nft startx; do
  command -v "$c" >/dev/null 2>&1 || { already_provisioned=0; break; }
done
if [ "$already_provisioned" = "1" ] && [ "${FORCE_PKG_INSTALL:-0}" != "1" ]; then
  ok "Host packages already present — skipping install (prebuilt image; no network needed)."
  PKG=skip
fi
[ "$PKG" = skip ] || log "Installing host packages via $PKG ..."
if [ "$PKG" = "skip" ]; then
  : # already provisioned (prebuilt image) — do not touch packages / network.
elif [ "$PKG" = "apk" ]; then
  # Enable the community repo (i3wm, virt-viewer live there).
  if ! grep -q '/community' /etc/apk/repositories 2>/dev/null; then
    # derive community line from the existing main line.
    main_line="$(grep -m1 '/main$' /etc/apk/repositories || true)"
    [ -n "$main_line" ] && echo "${main_line%/main}/community" >> /etc/apk/repositories
  fi
  apk update
  # WiFi firmware pkg is overridable (config.env WIFI_FIRMWARE_PKG).
  : "${WIFI_FIRMWARE_PKG:=linux-firmware}"
  apk add \
    linux-lts "$WIFI_FIRMWARE_PKG" \
    wpa_supplicant wireless-tools iw \
    qemu-system-x86_64 qemu-img qemu-modules \
    libvirt libvirt-daemon dbus polkit \
    virt-install virt-viewer \
    ovmf swtpm \
    nftables wireguard-tools \
    xorg-server xf86-video-modesetting xf86-input-libinput setxkbmap \
    xkeyboard-config xkbcomp \
    eudev udev-init-scripts keyd keyd-openrc usbguard usbguard-openrc usbutils \
    xinit i3wm xterm ttf-dejavu \
    adwaita-icon-theme hicolor-icon-theme \
    polybar jq font-jetbrains-mono-nerd \
    firefox-esr \
    xorriso \
    alpine-conf parted sgdisk cloud-utils-growpart e2fsprogs-extra cryptsetup cryptsetup-openrc \
    bash wget curl openssl gnupg
    # alpine-conf: provides setup-disk (used by 08 to install to internal disk).
    # firefox-esr: host browser for captive-portal (Entra) login only (07).
    # NOTE: NOT installing cloud-utils-localds on Alpine — it pulls cdrkit,
    # which conflicts with virt-install's xorriso (both provide mkisofs).
    # environments/create.sh builds the cloud-init seed ISO with xorriso/mkisofs.
else
  # ---- Debian-minimal alternative -----------------------------------------
  apt-get update
  apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    qemu-system-x86 qemu-utils \
    libvirt-daemon-system libvirt-clients \
    virtinst virt-viewer \
    ovmf swtpm \
    nftables wireguard-tools \
    xserver-xorg xinit i3 fonts-dejavu adwaita-icon-theme \
    cloud-image-utils genisoimage wget curl openssl
fi

# -----------------------------------------------------------------------------
# 7. Set the KVM nested-virt parameter (now OFF, see above) + load the module.
#    Written as a modprobe.d drop-in so it survives reboots.
# -----------------------------------------------------------------------------
log "Configuring $KVM_MODULE (nested virt disabled) ..."
echo "$NESTED_PARAM" > /etc/modprobe.d/kvm-nested.conf
# Autoload module at boot.
if [ -d /etc/modules-load.d ]; then
  echo "$KVM_MODULE" > /etc/modules-load.d/kvm.conf
else
  grep -q "^$KVM_MODULE" /etc/modules 2>/dev/null || echo "$KVM_MODULE" >> /etc/modules
fi
# USB keyboard/HID autoload (safe). Let udev handle i8042/i2c_hid from modaliases.
if [ -d /etc/modules-load.d ]; then
  printf 'usbhid\nhid_generic\n' > /etc/modules-load.d/keyboard.conf
fi
for m in usbhid hid_generic; do modprobe "$m" 2>/dev/null || true; done

# Load now (reload to pick up nested=0 if already loaded with it on).
modprobe -r "$KVM_MODULE" 2>/dev/null || true
modprobe "$KVM_MODULE"
# Verify nested is actually OFF (both vendors report N/0 when disabled).
nested_state="$(cat "/sys/module/${KVM_MODULE}/parameters/nested" 2>/dev/null || echo '?')"
case "$nested_state" in
  N|0) ok "Nested virt DISABLED (nested=$nested_state).";;
  *)   warn "Nested virt still on (nested=$nested_state) — a guest was likely already using $KVM_MODULE. Reboot to apply nested=0.";;
esac

# -----------------------------------------------------------------------------
# 8. Enable services (idempotent).
# -----------------------------------------------------------------------------
if command -v rc-update >/dev/null 2>&1; then          # OpenRC (Alpine)
  # udev needed for Xorg keyboard/mouse detection (idempotent).
  rc-update add udev sysinit || true
  rc-update add udev-trigger sysinit || true
  rc-update add udev-settle sysinit || true
  rc-update add udev-postmount default || true
  rc-service udev start 2>/dev/null || true
  rc-service udev-trigger start 2>/dev/null || true
  rc-update add libvirtd default || true
  rc-update add nftables default || true
  rc-service libvirtd start || true
elif command -v systemctl >/dev/null 2>&1; then        # systemd (Debian)
  systemctl enable --now libvirtd || true
  systemctl enable nftables || true
fi

# -----------------------------------------------------------------------------
# 9. Report.
# -----------------------------------------------------------------------------
ok "Host build staged. Detected values:"
cat "$CONFIG_ENV"
cat <<EOF

The rest of the host base (configure, harden, switching, Wi-Fi) is applied
AUTOMATICALLY at first boot. When the desktop is up, build the VMs from a root
shell on tty2 (Ctrl+Alt+F2):
    cd /opt/appliance && ./setup.sh        # numbered menu: 1) create  2) isolate
EOF
;;
configure)
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
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root
load_config
# Warn-only: these arrive with the package step in host/detect-and-install.sh and
# are not needed by anything this script writes. NOTE: `require_cmds ... || true`
# does NOT degrade to a warning — require_cmds calls die(), and an `exit` inside a
# function ends the whole script regardless of the `|| true`. So check by hand.
for _c in startx i3; do
  command -v "$_c" >/dev/null 2>&1 || warn "$_c not installed yet — the desktop will not start until host/detect-and-install.sh has installed it."
done

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
# netdev = the wpa_supplicant control-interface group (see host.sh wifi), so the
# unprivileged kiosk can add a Wi-Fi network at runtime via wpa_cli (Super+w) —
# no root, no sudo. Create it first so membership can be granted.
addgroup -S netdev 2>/dev/null || groupadd -r netdev 2>/dev/null || true
for g in libvirt libvirtd kvm video input netdev; do addgroup "$KIOSK_USER" "$g" 2>/dev/null || usermod -aG "$g" "$KIOSK_USER" 2>/dev/null || true; done
passwd -u "$KIOSK_USER" 2>/dev/null || true
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"; KIOSK_HOME="${KIOSK_HOME:-/home/$KIOSK_USER}"

# Root password for admin on tty2 — from config (HOST_ROOT_PASSWORD). Must be
# set explicitly; secrets are never auto-generated.
ROOT_PW="$(require_secret HOST_ROOT_PASSWORD)"
echo "root:$ROOT_PW" | chpasswd 2>/dev/null && log "Root password set (admin on tty2)." || warn "Failed to set root password."

# The kiosk desktop must be able to VIEW the environment VMs (virt-viewer
# --attach) and NOTHING more. Unauthenticated read-write access to qemu:///system
# is root-equivalent: the caller can `virsh define` a domain whose <disk> or
# <filesystem> maps a host block device / the host root and then read or write it
# as the qemu (root) context — reading config.env secrets or planting a root
# payload — and can repoint an existing domain's disk at a malicious image. The
# old `auth_unix_rw = "none"` handed the kiosk exactly that. So: require polkit
# for read-write actions and grant the kiosk, by rule, ONLY the lookup +
# open-graphics/screenshot actions the viewer performs. define / start / write /
# device-attach and the rest are denied. (SO-2 / treatment T-03 in the EBIOS RM
# risk analysis.)
if [ -f /etc/libvirt/libvirtd.conf ]; then
  # Default-deny every org.libvirt.api.* for the kiosk; allow only the view path.
  mkdir -p /etc/polkit-1/rules.d
  cat > /etc/polkit-1/rules.d/50-appliance-kiosk-libvirt.rules <<POLKIT
// Generated by src/host.sh configure — the kiosk may WATCH the VMs, not manage
// them. Read-write access to the system libvirt is root-equivalent; this rule is
// what keeps the (unprivileged, internet-facing) desktop from crossing into it.
polkit.addRule(function(action, subject) {
  if (subject.user !== "$KIOSK_USER") return polkit.Result.NOT_HANDLED;
  if (action.id.indexOf("org.libvirt.api.") !== 0) return polkit.Result.NOT_HANDLED;
  var view = {
    "org.libvirt.api.connect.getattr": 1, "org.libvirt.api.connect.read": 1,
    "org.libvirt.api.connect.search-domains": 1,
    "org.libvirt.api.domain.getattr": 1, "org.libvirt.api.domain.read": 1,
    "org.libvirt.api.domain.open-graphics": 1, "org.libvirt.api.domain.screenshot": 1
  };
  return view[action.id] ? polkit.Result.YES : polkit.Result.NO;
});
POLKIT
  chmod 644 /etc/polkit-1/rules.d/50-appliance-kiosk-libvirt.rules

  sed -i 's/^#*unix_sock_group.*/unix_sock_group = "libvirt"/'      /etc/libvirt/libvirtd.conf
  sed -i 's/^#*unix_sock_rw_perms.*/unix_sock_rw_perms = "0770"/'   /etc/libvirt/libvirtd.conf
  sed -i 's/^#*auth_unix_ro.*/auth_unix_ro = "none"/'               /etc/libvirt/libvirtd.conf
  sed -i 's/^#*auth_unix_rw.*/auth_unix_rw = "polkit"/'             /etc/libvirt/libvirtd.conf

  # polkit auth needs dbus + polkitd running, or libvirt fails CLOSED and the
  # viewer cannot connect at all. Enable + start both, then restart libvirtd.
  for svc in dbus polkit polkitd; do
    rc-update add "$svc" 2>/dev/null || true
    rc-service "$svc" start 2>/dev/null || rc-service "$svc" restart 2>/dev/null || true
  done
  rc-service libvirtd restart 2>/dev/null || true

  # SAFETY NET (fail SAFE, not closed): if polkit confinement locks the kiosk out
  # of libvirt entirely — polkit/dbus not functional here, or this build's action
  # IDs differ — the appliance would boot with NO working VM viewer. Prove the
  # kiosk can still reach the read path; if it cannot, revert to the previous
  # group access and warn loudly. A confinement that does not work on this host
  # then degrades to "works but unconfined" (operator sees the warning and the
  # residual SO-2 risk) instead of a bricked desktop. Verify the confinement on
  # real hardware after first boot: the kiosk must view VMs but be refused a
  # `virsh define`.
  if command -v virsh >/dev/null 2>&1 \
     && ! su -s /bin/sh "$KIOSK_USER" -c 'virsh -c qemu:///system -q list >/dev/null 2>&1'; then
    warn "libvirt: polkit confinement also blocked the kiosk's read path — reverting to auth_unix_rw=none (SO-2/T-03 NOT closed). Check dbus+polkit on this host."
    sed -i 's/^#*auth_unix_rw.*/auth_unix_rw = "none"/' /etc/libvirt/libvirtd.conf
    rc-service libvirtd restart 2>/dev/null || true
  else
    ok "libvirt: kiosk confined to view-only (polkit); define/start/device-attach denied."
  fi
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
#
# dbus-run-session: modern virt-viewer is a GtkApplication and will NOT create
# its window without a session D-Bus. The kiosk X session has none (no desktop
# environment starts one, and dbus-launch lives in dbus-x11 which we don't ship),
# so virt-viewer failed with "failed to execute child dbus-launch" / "could not
# create org.gnome.SessionManager" and every viewer stayed invisible — a black
# screen behind the i3 cursor. Start the whole session under one session bus so
# i3 and every virt-viewer it spawns inherit DBUS_SESSION_BUS_ADDRESS. If
# dbus-run-session is somehow missing, fall back to bare i3 rather than no WM.
if command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session -- i3
else
  exec i3
fi
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
# Runs as ROOT from udev. To pop the chooser on the kiosk X display we need its
# DISPLAY + XAUTHORITY. startx stores the cookie in ~/.serverauth.NNNN, NOT
# ~/.Xauthority (the exact trap vmswitch was fixed for in 281e7e3), so read the
# REAL values from the running i3 process env; fall back to globbing the home.
KU="$KIOSK_USER"
pid="\$(pgrep -u "\$KU" -x i3 | head -1)"
if [ -n "\$pid" ] && [ -r "/proc/\$pid/environ" ]; then
  DISPLAY="\$(tr '\0' '\n' < "/proc/\$pid/environ" | sed -n 's/^DISPLAY=//p'    | head -1)"
  XAUTHORITY="\$(tr '\0' '\n' < "/proc/\$pid/environ" | sed -n 's/^XAUTHORITY=//p' | head -1)"
fi
: "\${DISPLAY:=:0}"
[ -n "\$XAUTHORITY" ] || XAUTHORITY="\$(ls "$KIOSK_HOME"/.Xauthority "$KIOSK_HOME"/.serverauth.* 2>/dev/null | head -1)"
export DISPLAY XAUTHORITY
setsid xterm -geometry 60x18 -T "Route YubiKey" -e "$APP_DIR/src/host.sh" usb-to-vm >/dev/null 2>&1 &
EOF
  chmod +x /usr/local/bin/yubikey-plugged
  mkdir -p /etc/udev/rules.d
  # ENV{DEVTYPE}=="usb_device" matters: without it the rule also matches every
  # USB *interface* the key exposes (a YubiKey presents 3-4), so a single insert
  # fired the chooser several times and stacked duplicate xterms on top of each
  # other. One device node, one chooser.
  cat > /etc/udev/rules.d/99-yubikey-router.rules <<'URULE'
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="1050", RUN+="/usr/local/bin/yubikey-plugged"
URULE
  udevadm control --reload 2>/dev/null || true
  ok "YubiKey router active (auto-chooser on plug; Super+y = manual chooser)."
fi

ok "Host configured."
cat <<EOF

(On the prebuilt appliance this ran automatically at first boot; the USB
installer already committed the system to the internal disk via
src/host.sh install-to-disk — no manual setup-alpine step is needed.)

Next (operator): cd /opt/appliance && ./setup.sh    # 1) create the VMs  2) isolate + verify
EOF
;;
harden)
# =============================================================================
# host/harden.sh   (ANSSI #2 — socle durci à l'état de l'art)
# -----------------------------------------------------------------------------
# Hardens the host ("socle"): kernel sysctl hardening (always) + sshd hardening
# (always, if sshd is installed) + an optional default-DROP host INPUT
# firewall (nothing should connect TO the socle). This is defense for the base
# system itself; VM isolation is handled by 05.
#
# Runs at first boot (idempotent). Safe defaults: sysctls and sshd hardening
# are always applied; the host-input firewall is OPT-IN (HARDEN_INPUT=1) so it
# can't lock out an SSH you rely on during setup.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root
load_config

# -----------------------------------------------------------------------------
# 1. Kernel / network sysctl hardening (ANSSI état-de-l'art baseline).
# -----------------------------------------------------------------------------
log "Applying kernel sysctl hardening ..."
cat > /etc/sysctl.d/90-appliance-hardening.conf <<'EOF'
# --- kernel info leaks / attack surface ---
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.yama.ptrace_scope=1
kernel.kexec_load_disabled=1
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.perf_event_paranoid=3
kernel.randomize_va_space=2
fs.suid_dumpable=0
# --- filesystem link/fifo protections ---
fs.protected_symlinks=1
fs.protected_hardlinks=1
fs.protected_fifos=2
fs.protected_regular=2
# --- network anti-spoofing / no redirects / no source routing ---
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.log_martians=1
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_source_route=0
# --- no IPv6 routing through the host ---
# The appliance is IPv4-only by design (isolated libvirt nets define only v4;
# egress + inter-env DROP rules in environments/isolate.sh are all `ip ...`,
# i.e. v4-family). If IPv6 forwarding were ever on, a whitelist/isolated env's
# v6 traffic would bypass those rules entirely (the forward chain policy is
# accept). Keep v6 forwarding off so the egress lock cannot silently open for v6.
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.default.forwarding=0
EOF
# Apply now (ignore keys the running kernel lacks).
sysctl -p /etc/sysctl.d/90-appliance-hardening.conf 2>/dev/null || \
  while read -r line; do case "$line" in ''|\#*) continue;; esac; sysctl -w "$line" 2>/dev/null || true; done < /etc/sysctl.d/90-appliance-hardening.conf
ok "sysctl hardening applied."

# Disable core dumps (no sensitive memory to disk).
echo '* hard core 0' > /etc/security/limits.d/00-appliance-nocore.conf 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. SSH hardening — fail closed for the no-password kiosk account.
#    host/configure.sh creates KIOSK_USER unlocked (passwd -u) for tty1
#    console autologin, but NEVER gives it a password (empty/no password) —
#    it is meant for local console use only. If sshd happens to be installed
#    (the base ISO may ship it) and reachable — HOST_SSH=1 below explicitly
#    opens port 22, and with the default HARDEN_INPUT=0 there is no host
#    firewall at all — an empty password must NEVER be usable over the
#    network. Applied UNCONDITIONALLY (not gated on HARDEN_INPUT/HOST_SSH,
#    which only control the host firewall, not whether sshd itself runs). A
#    no-op if sshd isn't installed.
# -----------------------------------------------------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
  log "Hardening $SSHD_CONFIG (deny empty-password auth; deny kiosk over SSH) ..."
  [ -f "$SSHD_CONFIG.orig" ] || cp "$SSHD_CONFIG" "$SSHD_CONFIG.orig"

  # Fail closed regardless of distro/build default: never allow empty-password
  # auth over SSH. Fix the line in place if present (even if it says "yes"),
  # otherwise append it (it becomes the first — and effective — occurrence;
  # sshd_config uses the first value set for a given keyword).
  if grep -qiE '^[[:space:]]*PermitEmptyPasswords' "$SSHD_CONFIG"; then
    sed -i -E 's/^[[:space:]]*PermitEmptyPasswords.*/PermitEmptyPasswords no/I' "$SSHD_CONFIG"
  else
    printf '\nPermitEmptyPasswords no\n' >> "$SSHD_CONFIG"
  fi

  # Belt-and-braces: explicitly deny the kiosk account over SSH. It is a
  # local-console-only autologin account with no password at all; real
  # (root/admin) accounts keep whatever PasswordAuthentication is configured.
  KIOSK_USER="${KIOSK_USER:-kiosk}"
  deny_line="DenyUsers $KIOSK_USER"
  grep -qxF "$deny_line" "$SSHD_CONFIG" || printf '\n%s\n' "$deny_line" >> "$SSHD_CONFIG"

  # Reload sshd if it's actually running (no-op otherwise / if not installed).
  if command -v rc-service >/dev/null 2>&1 && rc-service sshd status >/dev/null 2>&1; then
    rc-service sshd reload 2>/dev/null || true
  elif command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet ssh 2>/dev/null; then
      systemctl reload ssh 2>/dev/null || true
    elif systemctl is-active --quiet sshd 2>/dev/null; then
      systemctl reload sshd 2>/dev/null || true
    fi
  fi
  ok "sshd hardened (PermitEmptyPasswords no; $KIOSK_USER denied over SSH)."
else
  log "No sshd_config found — nothing to harden (sshd not installed)."
fi

# -----------------------------------------------------------------------------
# 3. Host INPUT firewall (OPT-IN via HARDEN_INPUT=1). Default-DROP everything TO
#    the host except loopback, established/related, ICMP, and DHCP client. The
#    socle exposes no services. Set HOST_SSH=1 to keep sshd reachable (port 22).
# -----------------------------------------------------------------------------
if [ "${HARDEN_INPUT:-0}" = "1" ]; then
  log "Applying default-DROP host INPUT firewall ..."
  require_cmds nft
  # environments/isolate.sh creates this directory too, but harden runs FIRST at
  # first boot — without the mkdir the heredoc below fails and `set -e` aborts
  # hardening entirely.
  mkdir -p /etc/nftables.d
  ssh_rule=""
  [ "${HOST_SSH:-0}" = "1" ] && ssh_rule='    tcp dport 22 accept'
  cat > /etc/nftables.d/appliance-host-input.nft <<EOF
#!/usr/sbin/nft -f
table inet appliance_host_input
delete table inet appliance_host_input
table inet appliance_host_input {
  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
    udp sport 67 udp dport 68 accept    # DHCP client replies
$ssh_rule
    # Guests reach the host ONLY as their gateway, for DHCP + DNS on the isolated
    # bridges. This must be accepted HERE: nftables evaluates every base chain
    # registered on the input hook, and a drop in ANY of them is final — libvirt
    # accepting these in its own chain does not override our policy drop. Without
    # these three rules a guest never gets a DHCP lease and has no resolver, i.e.
    # HARDEN_INPUT=1 would silently take every environment offline.
    iifname "virbr*" udp dport 67 accept    # DHCP requests from guests
    iifname "virbr*" udp dport 53 accept    # DNS to the per-env gateway
    iifname "virbr*" tcp dport 53 accept
  }
}
EOF
  MAIN_NFT="/etc/nftables.nft"; [ -f "$MAIN_NFT" ] || MAIN_NFT="/etc/nftables.conf"
  if [ -f "$MAIN_NFT" ] && ! grep -q "appliance-host-input.nft" "$MAIN_NFT"; then
    echo "include \"/etc/nftables.d/appliance-host-input.nft\"" >> "$MAIN_NFT"
  fi
  nft -f /etc/nftables.d/appliance-host-input.nft && ok "Host INPUT firewall applied (default-drop)."
else
  log "HARDEN_INPUT=0 — host INPUT firewall not applied (set HARDEN_INPUT=1 to lock the socle down)."
fi

ok "Host hardening complete."
;;
switching)
# =============================================================================
# host/switching.sh
# -----------------------------------------------------------------------------
# Write the i3 config that turns the appliance into a 3-VM kiosk:
#   * workspace 1 = desktop VM viewer   (boot lands here)
#   * workspace 2 = devops VM viewer
#   * workspace 3 = analysis VM viewer
#   * Super+1/2/3 (or Ctrl+Alt+1/2/3) switch instantly between them
#   * each viewer fills the screen (below the trust bar when TRUST_BAR=1), no
#     borders, no gaps -> you never see the host
#
# Each virt-viewer is launched with --kiosk so the guest owns the whole surface.
# i3 assigns each viewer window to its workspace by matching window class/title.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root
load_config

# The desktop runs as the unprivileged kiosk user, so write its i3/viewer config
# into the kiosk home (not /root).
KIOSK_USER="${KIOSK_USER:-kiosk}"
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"; KIOSK_HOME="${KIOSK_HOME:-/home/$KIOSK_USER}"
I3_DIR="$KIOSK_HOME/.config/i3"
mkdir -p "$I3_DIR"
# Captive-portal helper (written by host/captive-portal.sh into the kiosk home).
# vmswitch launches it under the SPICE grab via keyd (below).
PORTAL_SH="$KIOSK_HOME/portal-login.sh"
# Dedicated workspaces for overlays so they are NOT hidden behind a fullscreen VM.
WS_PORTAL=8
WS_SHELL=9
WS_USB=7
WS_WIFI=6

# Super+w "add a Wi-Fi network" helper for the UNPRIVILEGED kiosk user. It talks
# to wpa_supplicant over its netdev-group control socket via wpa_cli — no root,
# no sudo — so someone can join a new (e.g. home) network from the desktop. The
# network is saved (update_config=1) and reconnects on the next boot.
WIFI_SH="$KIOSK_HOME/add-wifi.sh"
cat > "$WIFI_SH" <<'WIFI'
#!/bin/sh
# add-wifi.sh — add a Wi-Fi network as the unprivileged kiosk user (Super+w).
echo "=== Add a Wi-Fi network ==="
printf 'Network name (SSID): '; read -r ssid
[ -n "$ssid" ] || { echo "No SSID given — aborting."; sleep 2; exit 1; }
printf 'Password (leave empty for an open network): '
stty -echo 2>/dev/null; read -r psk; stty echo 2>/dev/null; echo
if ! wpa_cli status >/dev/null 2>&1; then
  echo "Wi-Fi is not available (no wireless hardware / wpa_supplicant not running)."
  echo "Press Enter to close."; read -r _; exit 1
fi
id="$(wpa_cli add_network 2>/dev/null | tail -1)"
case "$id" in ''|*[!0-9]*) echo "Could not add a network (wpa_cli error)."; sleep 3; exit 1 ;; esac
wpa_cli set_network "$id" ssid "\"$ssid\"" >/dev/null 2>&1
if [ -n "$psk" ]; then
  wpa_cli set_network "$id" psk "\"$psk\"" >/dev/null 2>&1
else
  wpa_cli set_network "$id" key_mgmt NONE >/dev/null 2>&1
fi
wpa_cli enable_network "$id" >/dev/null 2>&1
wpa_cli select_network "$id" >/dev/null 2>&1
wpa_cli save_config  >/dev/null 2>&1   # persist for next boot (update_config=1)
echo; echo "Added '$ssid'. Associating ..."; sleep 6
wpa_cli status 2>/dev/null | grep -E 'wpa_state=|^ssid=|ip_address=' || true
echo; echo "Saved. No ip_address yet? It will connect on the next boot (or move"
echo "closer / re-check the password). Press Enter to close."; read -r _
WIFI
chmod +x "$WIFI_SH"
chown "$KIOSK_USER:$KIOSK_USER" "$WIFI_SH" 2>/dev/null || true

log "Writing $I3_DIR/config (per enabled environment) ..."
# Static header (quoted heredoc keeps i3 $vars literal).
cat > "$I3_DIR/config" <<'EOF'
# ===== VM-kiosk i3 config (generated by host/switching.sh) =====
set $mod Mod4
font pango:DejaVu Sans Mono 8
default_border none
default_floating_border none
hide_edge_borders both
focus_follows_mouse no

bindsym $mod+Tab workspace next
bindsym $mod+Shift+r restart
bindsym $mod+Shift+q kill
# Terminal on a dedicated workspace so it's not hidden behind a fullscreen VM.
# NOTE: X/i3 run as the unprivileged kiosk user, so this is a KIOSK shell, not
# root. Root admin lives on tty2 (Ctrl+Alt+F2). Super+Return.
bindsym $mod+Return workspace number WS_SHELL_N; exec xterm
for_window [class="(?i)xterm"] floating enable, border normal
# Super+y = route a plugged YubiKey (or USB) to a chosen VM (manual fallback).
# Like the other hotkeys this ALSO has to switch to an empty workspace first,
# or the chooser xterm opens behind the focused VM and is never seen. The chord
# itself is delivered by keyd (below) so it survives the SPICE keyboard grab;
# this i3 binding only covers the case where no viewer holds the keyboard.
bindsym $mod+y workspace number WS_USB_N; exec --no-startup-id xterm -T "Route YubiKey" -e HOMEDIR_APP/src/host.sh usb-to-vm
# Super+w = add a new Wi-Fi network (e.g. working from home) as the unprivileged
# kiosk user, via wpa_cli. No root needed (kiosk is in the netdev control group).
bindsym $mod+w workspace number WS_WIFI_N; exec --no-startup-id xterm -T "Add Wi-Fi" -e WIFI_HELPER
EOF
# Bake the real appliance path + overlay workspace numbers into the header
# (it is a quoted heredoc, so nothing expanded there).
sed -i -e "s|HOMEDIR_APP|$APP_ROOT|" \
       -e "s|WIFI_HELPER|$WIFI_SH|" \
       -e "s|WS_SHELL_N|$WS_SHELL|" \
       -e "s|WS_USB_N|$WS_USB|" \
       -e "s|WS_WIFI_N|$WS_WIFI|" "$I3_DIR/config"

# Per ENABLED env: title-match the viewer to its numbered workspace, bind
# Super+<idx>, and launch its viewer. Workspaces are named "<idx>: <ENV>" for the
# ANSSI trust bar. Switching uses `workspace number` so the label doesn't matter.
first_idx=""
for_each_enabled_env | while read -r env idx; do
  label="$(env_title "$env")"
  cat >> "$I3_DIR/config" <<EOF

# --- $env (workspace $idx) ---
# NOTE: no Super+<n> switch binding here on purpose. Super/Meta is left to the
# guest (Windows uses Super+1..9 for the taskbar), and an i3 root-grab bind only
# fires when a guest is NOT holding the keyboard grab anyway. VM switching is
# Ctrl+Alt+<n>, delivered by keyd below X so it works even under the SPICE grab.
for_window [class="(?i)virt-viewer" title="(?i)$env"] move to workspace "$idx: $label", border none
exec --no-startup-id sh -c 'exec ~/vm-viewer.sh $env'
EOF
done
# Land on the first enabled env at boot.
# NOTE: awk 'NR==1' (not '| head -1') — head closes the pipe early, which under
# 'set -o pipefail' makes for_each_enabled_env fail with SIGPIPE and aborts the
# whole script (that truncated the config: no trust bar, no vm-viewer, no keyd).
first_idx="$(for_each_enabled_env | awk 'NR==1{print $2}')"
echo "exec --no-startup-id i3-msg workspace number ${first_idx:-1}" >> "$I3_DIR/config"

# -----------------------------------------------------------------------------
# ANSSI barre de confiance + fullscreen mode (TRUST_BAR).
#  TRUST_BAR=1 (default, ANSSI): a colored bar is ALWAYS visible showing which
#    environment is active; viewers tile below it (not fullscreen), so the bar
#    can never be hidden by a guest.
#  TRUST_BAR=0: guests go true fullscreen (edge-to-edge), no persistent bar.
# -----------------------------------------------------------------------------
: "${TRUST_BAR:=1}"
PB_DIR="$KIOSK_HOME/.config/polybar"
if [ "$TRUST_BAR" = "1" ]; then
  # Viewers are WINDOWED (VIEWER_FS=""), not --full-screen. A true-fullscreen
  # (EWMH) viewer is raised by i3 ABOVE docks/override-redirect windows, so the
  # trust bar was always hidden behind the VM. Instead the polybar reserves a top
  # strut (override-redirect=false) and i3 tiles the borderless viewer BELOW it —
  # so the bar can NEVER be covered, which is the whole ANSSI point. The one
  # leftover, virt-viewer's windowed CSD header row (hardwired to fullscreen-only
  # in its source), is collapsed to zero height by the kiosk user's gtk.css
  # (below), so the guest display gets the entire tile — visually fullscreen,
  # with the trust bar always on top.
  VIEWER_FS=""
  log "Writing custom polybar trust bar into $PB_DIR ..."
  cat >> "$I3_DIR/config" <<EOF

# --- Trust bar: custom polybar (ANSSI always-visible active-env indicator) ---
# polybar reserves the top strut, so viewers tile below it and can't hide it.
exec_always --no-startup-id $PB_DIR/launch.sh
# Guard: never let a viewer go fullscreen — an EWMH-fullscreen window is raised
# above the strut and would HIDE the trust bar (ANSSI trust-indicator escape).
for_window [class="(?i)virt-viewer"] fullscreen disable
EOF
  mkdir -p "$PB_DIR"

  # Build per-env name/color lookups. Workspace number == env index, so the bar
  # can color itself from the focused workspace alone. Palette cycles if there
  # are more envs than colors. Strong, distinct hues: blue/green/red/amber/...
  palette="#3b82f6 #22c55e #ef4444 #f59e0b #a855f7 #06b6d4 #ec4899"
  name_cases=""; color_cases=""; egress_cases=""; vpn_cases=""; all_idx=""
  while read -r _env _idx; do
    [ -n "$_env" ] || continue
    _lbl="$(env_title "$_env")"
    _col="$(echo "$palette" | awk -v n="$_idx" '{print $(((n-1)%NF)+1)}')"
    [ -n "$_col" ] || _col="#3b82f6"
    # Mirror isolate.sh's emit_egress exactly: it treats ANY mode that is not
    # literally "whitelist" as open egress. Normalising the same way here keeps
    # the bar from promising "filtered" for a typo the firewall ignores.
    _egr="$(env_val "$_env" EGRESS_MODE all)"
    [ "$_egr" = "whitelist" ] || _egr="all"
    name_cases="${name_cases}    $_idx) printf '%s' '$_lbl' ;;
"
    color_cases="${color_cases}    $_idx) printf '%s' '$_col' ;;
"
    egress_cases="${egress_cases}    $_idx) printf '%s' '$_egr' ;;
"
    # <env>_VPN=1 means environments/vpn.sh drops this env's direct WAN path and
    # only lets wg<idx> out. Baking the *intent* (not the current link state) is
    # what lets the bar tell "no tunnel wanted" apart from "tunnel is DOWN".
    if [ "$(env_val "$_env" VPN 0)" = "1" ]; then
      vpn_cases="${vpn_cases}    $_idx) return 0 ;;
"
    fi
    all_idx="$all_idx $_idx"
  done <<EOF
$(for_each_enabled_env)
EOF

  # Label the overlay workspaces too (Super+p portal = $WS_PORTAL, Super+Return
  # shell = $WS_SHELL, Super+y USB chooser = $WS_USB) so the trust bar always
  # names what you are looking at — an unlabelled workspace would show the
  # generic "ENV" pill, which is exactly the confusion the bar exists to prevent.
  name_cases="${name_cases}    $WS_PORTAL) printf '%s' 'PORTAL' ;;
    $WS_SHELL) printf '%s' 'SHELL' ;;
    $WS_USB) printf '%s' 'USB' ;;
"
  color_cases="${color_cases}    $WS_PORTAL) printf '%s' '#f59e0b' ;;
    $WS_SHELL) printf '%s' '#6b6b6b' ;;
    $WS_USB) printf '%s' '#6b6b6b' ;;
"

  # active-env.sh: the left module. A rounded colored "pill" with the ACTIVE env
  # name (recolors live on switch) + per-env security posture (egress filter,
  # VPN up/down) + one dot per env. Renders via i3 events, so it needs no
  # polybar-i3 support (just i3-msg + jq). Header (lookups) is an expanding
  # heredoc; the render logic below is a quoted heredoc (kept literal).
  # PAD_WIDTH: the pill is padded to the LONGEST label so its width never
  # changes with the active env — otherwise everything right of the pill
  # (posture indicators, dots) reflowed on every workspace switch. The bar
  # font is monospace, so plain space padding is exact.
  _pad=6   # PORTAL / SHELL / USB overlay labels are <= 6 chars
  while read -r _env _idx; do
    [ -n "$_env" ] || continue
    _l="$(env_title "$_env")"
    [ "${#_l}" -gt "$_pad" ] && _pad="${#_l}"
  done <<EOF
$(for_each_enabled_env)
EOF
  cat > "$PB_DIR/active-env.sh" <<EOF
#!/bin/sh
# Generated by host/switching.sh — do not edit.
PAD_WIDTH=$_pad
name_of(){ case "\$1" in
$name_cases    *) printf 'ENV' ;;
  esac; }
color_of(){ case "\$1" in
$color_cases    *) printf '#3b82f6' ;;
  esac; }
# Per-workspace security posture, baked at generation time: render() re-runs on
# EVERY workspace event, so it must never re-read config.env — these case
# statements are the whole lookup cost. egress_of prints 'all' or 'whitelist'
# (same normalisation as isolate.sh's emit_egress); vpn_wanted returns 0 when
# <env>_VPN=1, i.e. environments/vpn.sh forces that env through wg<idx> — the
# INTENT, not the link state, so render can tell "no tunnel wanted" apart from
# "tunnel wanted but DOWN".
egress_of(){ case "\$1" in
$egress_cases    *) printf 'all' ;;
  esac; }
vpn_wanted(){ case "\$1" in
$vpn_cases    *) return 1 ;;
  esac; }
ALL_IDX="$all_idx"
EOF
  cat >> "$PB_DIR/active-env.sh" <<'EOF'
render(){
  n="$(i3-msg -t get_workspaces 2>/dev/null | jq -r '.[]|select(.focused).num' 2>/dev/null)"
  [ -n "$n" ] || n=1
  c="$(color_of "$n")"; nm="$(name_of "$n")"
  # Fixed-width pill: pad to the longest label (PAD_WIDTH, baked at generation)
  # so switching envs never reflows the indicators/dots right of the pill.
  nm="$(printf "%-${PAD_WIDTH}s" "$nm")"
  # Security posture next to the env name. Keep this CHEAP: the lookups above
  # are baked case statements, and the only probe is a single `ip -o link show`
  # that runs solely when the focused env actually wants a tunnel.
  ind=""
  # Whitelist egress is the higher-assurance mode — say so on the bar.
  [ "$(egress_of "$n")" = "whitelist" ] && ind="  %{F#f59e0b}filtered%{F-}"
  if vpn_wanted "$n"; then
    # environments/vpn.sh names the per-env interface wg<idx>. GREEN lock when
    # the tunnel interface exists, red 'vpn down' when it is wanted but absent
    # (vpn.sh drops the direct WAN path, so a missing wg<idx> means NO network —
    # exactly what the operator must see at a glance).
    if ip -o link show 2>/dev/null | grep -q ": wg${n}:"; then
      ind="${ind}  %{F#22c55e} vpn%{F-}"
    else
      ind="${ind}  %{F#ef4444} vpn down%{F-}"
    fi
  fi
  cap_l="%{T2}%{F${c}}%{T-}"                              # left rounded cap
  cap_r="%{T2}%{F${c}}%{T-}"                              # right rounded cap
  pill="${cap_l}%{B${c}}%{F#0d0d0f}  ${nm}  %{F-}%{B-}${cap_r}"
  dots=""
  for i in $ALL_IDX; do
    ci="$(color_of "$i")"
    if [ "$i" = "$n" ]; then dots="${dots}  %{F${ci}}%{F-}"
    else dots="${dots}  %{F#3a3a3a}%{F-}"; fi
  done
  printf '%s%s    %s   \n' "$pill" "$ind" "$dots"
}
render
i3-msg -t subscribe -m '[ "workspace" ]' 2>/dev/null | while read -r _ev; do render; done
EOF

  # Right-side modules (custom scripts -> no hardcoded interface/battery names).
  cat > "$PB_DIR/net.sh" <<'EOF'
#!/bin/sh
i="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
[ -n "$i" ] || { echo "%{F#ef4444} offline%{F-}"; exit 0; }
echo "%{F#8ab4f8}%{F-} $i"
EOF
  cat > "$PB_DIR/vpn.sh" <<'EOF'
#!/bin/sh
if ip -o link show 2>/dev/null | grep -qE ': wg[0-9]'; then
  echo "%{F#22c55e} vpn%{F-}"
else
  echo "%{F#4a4a4a} vpn%{F-}"
fi
EOF
  cat > "$PB_DIR/battery.sh" <<'EOF'
#!/bin/sh
cap="$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)"
[ -n "$cap" ] || exit 0
ac="$(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)"
ic=""; [ "$ac" = "1" ] && ic=""
echo "%{F#e8e8ea}$ic ${cap}%%{F-}"
EOF

  # isolation.sh: CONTRACT A consumer. host/isolation-watch.sh publishes one
  # TAB-separated line 'STATE EPOCH DETAIL' to /run/appliance/isolation.status;
  # this module stays INVISIBLE while the verdict is OK and only lights up on
  # FAIL/UNKNOWN (a permanent green pill was noise). It must NEVER crash and
  # never write to stderr (polybar would paint the error into the bar): a
  # missing or unparsable file is simply UNKNOWN. ISOLATION_STATUS_FILE
  # overrides the path for tests; production uses the default.
  cat > "$PB_DIR/isolation.sh" <<'EOF'
#!/bin/sh
# Generated by host/switching.sh — do not edit.
# QUIET BY DESIGN: OK prints EMPTY (polybar hides the module) — a green
# "isolated" pill told the operator nothing and just ate bar space. Only the
# states that need eyes render: FAIL loud, UNKNOWN as a question mark.
STATUS="${ISOLATION_STATUS_FILE:-/run/appliance/isolation.status}"
state="$(cut -f1 "$STATUS" 2>/dev/null)"
case "$state" in
  OK)   : ;;
  FAIL) echo "%{F#ef4444} ISOLATION FAIL%{F-}" ;;
  *)    echo "%{F#f59e0b} isolation ?%{F-}" ;;
esac
exit 0
EOF

  # polybar bar definition.
  cat > "$PB_DIR/config.ini" <<'EOF'
[colors]
bg  = #0d0d0f
fg  = #e8e8ea
mut = #6b6b6b

[bar/trust]
width  = 100%
height = 18
radius = 0
background = ${colors.bg}
foreground = ${colors.fg}
; font-0 = normal text/icons, font-1 = big glyphs for the rounded pill caps
font-0 = JetBrainsMono Nerd Font:size=8;2
font-1 = JetBrainsMono Nerd Font:size=11;3
padding-left  = 1
padding-right = 2
module-margin = 2
modules-left  = env
; No cpu/memory percentages: host load is meaningless to the operator — what
; matters is the VM on screen, and qemu burns host CPU by design. The
; isolation module is quiet while OK (it only renders on FAIL/UNKNOWN).
modules-right = isolation net vpn battery date
; NOT override-redirect: this makes polybar a real dock that RESERVES a top strut,
; so i3 tiles the (windowed, non-fullscreen) VM viewers below it and the bar can
; never be covered. An override-redirect bar does NOT reserve space and gets
; painted over by a fullscreen viewer — which is exactly why it was invisible.
override-redirect = false
wm-restack = i3
enable-ipc = true

[module/env]
type = custom/script
exec = ~/.config/polybar/active-env.sh
tail = true

; Leftmost right-side module: the host isolation verdict (CONTRACT A), so a
; FAIL is visible even before you read which env is active.
[module/isolation]
type = custom/script
exec = ~/.config/polybar/isolation.sh
interval = 3

[module/net]
type = custom/script
exec = ~/.config/polybar/net.sh
interval = 3

[module/vpn]
type = custom/script
exec = ~/.config/polybar/vpn.sh
interval = 3

[module/battery]
type = custom/script
exec = ~/.config/polybar/battery.sh
interval = 15

[module/date]
type = internal/date
interval = 5
date = %a %d %b
time = %H:%M
label = %{F#8ab4f8}%{F-} %date%  %time%
EOF

  # launch.sh: (re)start polybar cleanly on every i3 (re)start.
  cat > "$PB_DIR/launch.sh" <<'EOF'
#!/bin/sh
pkill -x polybar 2>/dev/null
for _ in 1 2 3 4 5; do pgrep -x polybar >/dev/null || break; sleep 0.2; done
polybar -q -c "$HOME/.config/polybar/config.ini" trust >/tmp/polybar.log 2>&1 &
EOF

  chmod +x "$PB_DIR"/*.sh
else
  VIEWER_FS="--full-screen"
  cat >> "$I3_DIR/config" <<'EOF'

# TRUST_BAR=0: guests fullscreen, no persistent bar.
for_window [class="(?i)virt-viewer"] fullscreen enable, border none
EOF
fi
# vm-viewer.sh reads this to decide fullscreen vs windowed (below the trust bar).
echo "$VIEWER_FS" > "$KIOSK_HOME/.vm-viewer-fs"

# -----------------------------------------------------------------------------
# Watchdog launcher: keeps each viewer alive and correctly titled. If a guest
# reboots or the viewer dies, this respawns it so the kiosk never shows the WM
# background (i.e. never "shows the host").
# -----------------------------------------------------------------------------
log "Writing $KIOSK_HOME/vm-viewer.sh (respawning full-screen launcher) ..."
# NOTE: --full-screen, NOT --kiosk. --kiosk takes a full keyboard grab via SPICE
# so i3's Super+1/2/3 never reach the WM (can't switch VMs). --full-screen lets
# i3 manage/switch the windows. i3 forces fullscreen+no-border (see above), so
# the guest still fills the screen edge-to-edge.
cat > "$KIOSK_HOME/vm-viewer.sh" <<'EOF'
#!/bin/sh
# vm-viewer.sh <domain> — keep a virt-viewer attached to <domain>. Runs as the
# kiosk user (i3 exec), so $HOME is the kiosk home.
# FS = "--full-screen" (TRUST_BAR=0) or "" (TRUST_BAR=1, tiled below trust bar),
# written by host/switching.sh into ~/.vm-viewer-fs.
vm="$1"
FS="$(cat "$HOME/.vm-viewer-fs" 2>/dev/null || echo --full-screen)"
# Dark GTK theme so any residual virt-viewer chrome blends into the dark bezel
# (the windowed header itself is collapsed to zero height by ~/.config/gtk-3.0/
# gtk.css — see switching.sh). What little GTK draws sits BELOW the trust bar,
# so it never occludes the ANSSI trust indicator.
export GTK_THEME="Adwaita:dark"
while true; do
  # NOTE: no --title (this virt-viewer build rejects it). The window title comes
  # from the domain name, which the i3 for_window rules match on.
  # SPICE grabs the keyboard while the guest is focused, so i3's Super hotkeys are
  # eaten. keyd (evdev, below X) handles switching; Ctrl+Alt also releases the grab.
  # NO toggle-fullscreen hotkey: a fullscreen (EWMH) viewer is raised ABOVE the
  # polybar strut and would HIDE the trust bar — an ANSSI trust-indicator escape.
  # --auto-resize always: guest framebuffer tracks the windowed tile below the bar.
  virt-viewer \
    --connect qemu:///system \
    $FS \
    --auto-resize always \
    --hotkeys=release-cursor=ctrl+alt \
    --wait \
    --reconnect \
    --attach "$vm" \
    2>/tmp/viewer-$vm.log
  # If the viewer exits (guest off / disconnect), wait then relaunch.
  sleep 2
done
EOF
chmod +x "$KIOSK_HOME/vm-viewer.sh"

# virt-viewer settings (GKeyFile — there is NO gsettings schema). share-clipboard
# =false keeps clipboard from crossing security domains (multilevel isolation);
# ask-quit=false suppresses the quit dialog in the kiosk.
VV_DIR="$KIOSK_HOME/.config/virt-viewer"
mkdir -p "$VV_DIR"
cat > "$VV_DIR/settings" <<'EOF'
[virt-viewer]
share-clipboard=false
ask-quit=false
EOF

# Collapse virt-viewer's windowed header bar to nothing. With TRUST_BAR=1 the
# viewer is a borderless i3 tile under the trust bar, but virt-viewer still
# draws a ~1-row CSD header in windowed mode — it is hardwired to fullscreen-
# only in virt-viewer's source (no gsettings/flag/keyfile disables it), which
# left an ugly black strip and a guest that never quite filled the screen. GTK
# user CSS is the one lever left: zero the headerbar's height, padding, icons
# and title so the display widget gets the WHOLE tile. Best-effort cosmetics —
# if a GTK/virt-viewer update changes the widget names, the strip comes back
# but nothing breaks.
mkdir -p "$KIOSK_HOME/.config/gtk-3.0"
cat > "$KIOSK_HOME/.config/gtk-3.0/gtk.css" <<'EOF'
/* Generated by host/switching.sh — hide virt-viewer's windowed chrome. */
/* CSD header bar (newer virt-viewer builds). */
headerbar {
  min-height: 0;
  padding: 0;
  margin: 0;
  border-width: 0;
  box-shadow: none;
  background: #0d0d0f;
}
headerbar .title, headerbar .subtitle { font-size: 0; }
headerbar button, headerbar button image {
  min-height: 0;
  min-width: 0;
  padding: 0;
  margin: 0;
}
headerbar separator { min-width: 0; }
/* Traditional GtkMenuBar + toolbar (older virt-viewer builds draw these instead
   of a CSD header — the "menus" that were still showing). Collapse them the same
   way. Which one a build uses depends on its GTK version, so we zero BOTH. */
menubar, .menubar,
toolbar, .toolbar {
  min-height: 0;
  padding: 0;
  margin: 0;
  border-width: 0;
  box-shadow: none;
  background: #0d0d0f;
  font-size: 0;
}
menubar > menuitem, .menubar > menuitem {
  min-height: 0;
  padding: 0;
  margin: 0;
  font-size: 0;
}
menubar menuitem label { font-size: 0; }
toolbar button, .toolbar button, toolbar button image {
  min-height: 0;
  min-width: 0;
  padding: 0;
  margin: 0;
  -gtk-icon-size: 0;
}
EOF
# Own all kiosk desktop config (i3, viewer, fs flag) by the kiosk user.
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config" "$KIOSK_HOME/vm-viewer.sh" "$KIOSK_HOME/.vm-viewer-fs" 2>/dev/null || true

# -----------------------------------------------------------------------------
# SEAMLESS SWITCHING under the SPICE keyboard grab.
# SPICE grabs the X keyboard while a guest is focused, so i3's Super+<n> never
# fire. keyd reads the keyboard at the KERNEL/evdev layer (BELOW X), so it sees
# the chord even while SPICE holds the X grab, and runs i3-msg — no release dance.
# -----------------------------------------------------------------------------
log "Writing /usr/local/bin/vmswitch + keyd hotkeys ..."
mkdir -p /usr/local/bin /etc/keyd
# keyd runs vmswitch as ROOT; point it at the kiosk user's X session so i3-msg
# reaches the kiosk's i3 (unquoted heredoc bakes the kiosk home; \$1 stays literal).
cat > /usr/local/bin/vmswitch <<EOF
#!/bin/sh
export PATH=/usr/local/bin:/usr/bin:/bin
# Called by keyd (as ROOT) on a global hotkey. Talks to the kiosk user's i3.
# Reaching that i3 from root is the whole difficulty, and where switching quietly
# died before: i3-msg with no socket falls back to reading the I3_SOCKET_PATH X
# property, which needs a WORKING DISPLAY+XAUTHORITY — and startx often puts the
# cookie in ~/.serverauth.NNNN, not ~/.Xauthority, so a hardcoded path failed
# auth and the switch did nothing. We now pull DISPLAY, XAUTHORITY *and* I3SOCK
# straight from the running i3's own environment, and talk to the IPC socket
# DIRECTLY (-s) so no X round-trip is needed at all.
KU="$KIOSK_USER"
KH="\$(getent passwd "\$KU" | cut -d: -f6)"
pid="\$(pgrep -u "\$KU" -x i3 | head -1)"
if [ -n "\$pid" ] && [ -r "/proc/\$pid/environ" ]; then
  DISPLAY="\$(tr '\0' '\n' < "/proc/\$pid/environ" | sed -n 's/^DISPLAY=//p'    | head -1)"
  XAUTHORITY="\$(tr '\0' '\n' < "/proc/\$pid/environ" | sed -n 's/^XAUTHORITY=//p' | head -1)"
  I3SOCK="\$(tr '\0' '\n' < "/proc/\$pid/environ" | sed -n 's/^I3SOCK=//p'      | head -1)"
fi
: "\${DISPLAY:=:0}"
[ -n "\$XAUTHORITY" ] || XAUTHORITY="\$(ls "\$KH"/.Xauthority "\$KH"/.serverauth.* 2>/dev/null | head -1)"
export DISPLAY XAUTHORITY
# Ask i3 itself for the socket if the environ didn't have it (older i3 doesn't
# export I3SOCK). Then prefer -s <sock>; only fall back to the X-property path.
[ -n "\$I3SOCK" ] || I3SOCK="\$(su -s /bin/sh "\$KU" -c 'i3 --get-socketpath' 2>/dev/null)"
MSG="i3-msg"; [ -n "\$I3SOCK" ] && MSG="i3-msg -s \$I3SOCK"
# Breadcrumb so a dead hotkey is diagnosable: if this file grows on each press,
# keyd is firing and the problem is downstream; if it never appears, keyd isn't.
# Log under a root-only dir in /run, NOT a fixed /tmp path: this helper runs as
# root on every hotkey, and any local user (incl. the kiosk) could pre-plant
# /tmp/vmswitch.log as a symlink onto a root-owned file and have root corrupt it
# here. /run is root-owned tmpfs the kiosk cannot write, so it cannot pre-create
# this dir or a symlink inside it.
VMSW_LOGD=/run/appliance; mkdir -p "\$VMSW_LOGD" 2>/dev/null; chmod 700 "\$VMSW_LOGD" 2>/dev/null
VMSW_LOG="\$VMSW_LOGD/vmswitch.log"
echo "\$(date '+%H:%M:%S') arg=\$1 disp=\$DISPLAY sock=\${I3SOCK:-NONE} pid=\${pid:-NONE}" >> "\$VMSW_LOG" 2>&1
# term/portal switch to a dedicated EMPTY workspace first, then exec — otherwise
# the xterm/browser opens behind the focused VM's fullscreen window and is never
# seen. Switching away also drops SPICE's keyboard grab, so normal keys work there.
case "\$1" in
  term)   \$MSG "workspace number $WS_SHELL; exec xterm" ;;
  portal) \$MSG "workspace number $WS_PORTAL; exec $PORTAL_SH" ;;
  usb)    \$MSG "workspace number $WS_USB; exec xterm -T 'Route YubiKey' -e $APP_ROOT/src/host.sh usb-to-vm" ;;
  *)      \$MSG workspace number "\$1" ;;
esac >> "\$VMSW_LOG" 2>&1
EOF
chmod +x /usr/local/bin/vmswitch

# Generate keyd bindings: Ctrl+Alt+<idx> -> switch to that env's workspace, for
# every ENABLED env. command() fires below X (works under the SPICE grab) and
# swallows the chord, so the switch works even while the guest holds the keyboard.
# Super/Meta is deliberately NOT used for switching: it is left to the guest
# (Windows uses Super+1..9 for the taskbar). Ctrl+Alt+<number row> is not a VT
# switch (those are the F-keys), so it is safe to bind.
# keyd v2.x has NO generic 'control'/'alt'/'meta' modifier tokens — those are
# rejected as "not a valid key" and the whole binding is silently dropped (which
# is exactly why every hotkey was dead). It only accepts the side-specific key
# names from `keyd list-keys`: leftcontrol/leftalt/leftmeta. Use those.
{
  echo "[ids]"; echo "*"; echo; echo "[main]"
  for_each_enabled_env | while read -r env idx; do
    echo "leftcontrol+leftalt+$idx = command(/usr/local/bin/vmswitch $idx)"
  done
  echo "leftmeta+enter = command(/usr/local/bin/vmswitch term)"
  # Super+p (captive-portal login) and Super+y (route a YubiKey to one VM) must
  # also work UNDER the SPICE grab, so route them through keyd like the workspace
  # keys — an i3-only bindsym never fires while a guest holds the keyboard grab,
  # which is the normal state of this kiosk. Super+y was i3-only and therefore
  # dead in practice.
  echo "leftmeta+p = command(/usr/local/bin/vmswitch portal)"
  echo "leftmeta+y = command(/usr/local/bin/vmswitch usb)"
} > /etc/keyd/default.conf

# keyd creates its virtual keyboard via /dev/uinput — without the uinput module
# keyd fails to start and NO switch hotkey fires on ANY environment. Load it now
# and persist it across reboots (belt-and-suspenders with build.sh's
# modules-load.d), then start keyd.
modprobe uinput 2>/dev/null || true
if [ -d /etc/modules-load.d ]; then
  grep -qx uinput /etc/modules-load.d/keyd.conf 2>/dev/null || echo uinput > /etc/modules-load.d/keyd.conf
fi
[ -e /dev/uinput ] || warn "/dev/uinput is missing — the kernel has no uinput support; keyd (and the switch hotkeys) cannot work until it does."

# Enable keyd (idempotent) AND confirm it is actually running — a keyd that is
# installed but not started is the single most common reason the hotkeys "do
# nothing", and silencing that with `|| true` hid it. Say so out loud instead.
if command -v rc-update >/dev/null 2>&1; then
  rc-update add keyd default 2>/dev/null || true
  rc-service keyd restart 2>/dev/null || rc-service keyd start 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now keyd 2>/dev/null || true
fi
# keyd needs a moment to grab the evdev devices after (re)start.
for _ in 1 2 3 4 5; do pgrep -x keyd >/dev/null 2>&1 && break; sleep 0.3; done
if pgrep -x keyd >/dev/null 2>&1; then
  ok "keyd is running — global switch hotkeys are live."
else
  warn "keyd is NOT running — the VM switch hotkeys will not work until it is. Try: rc-service keyd start (or: systemctl start keyd), then check 'keyd monitor' sees your keys."
fi

ok "Switching configured for enabled envs: $(for_each_enabled_env | awk '{printf "%s(Super+%s / Ctrl+Alt+%s) ",$1,$2,$2}'). Super+Enter = host shell."
cat <<EOF

Next (operator): cd /opt/appliance && ./setup.sh    # 1) create the VMs  2) isolate + verify
EOF
;;
wifi)
# =============================================================================
# host/wifi.sh
# -----------------------------------------------------------------------------
# Bring up WiFi as the HOST uplink so the three VMs get NAT internet over it.
# WiFi does NOT weaken VM isolation: the VMs never touch wlan0 directly — they
# sit on their own isolated bridges and are NAT'd out whatever the default-route
# interface is (05 auto-detects it, which then resolves to wlan0).
#
# Run this BEFORE 05 (05 needs a working default route to detect WAN + NAT).
# On the prebuilt image, first-boot runs this automatically ONLY if WIFI_SSID
# is set in config.env; otherwise run it by hand on the appliance.
#
# SECURITY: the PSK is hashed with wpa_passphrase; plaintext PSK is not written
# to wpa_supplicant.conf. The file is chmod 600.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root
load_config
require_cmds wpa_supplicant wpa_passphrase iw

# -----------------------------------------------------------------------------
# 0. Nothing to do if no SSID configured (host stays on wired).
# -----------------------------------------------------------------------------
if [ -z "${WIFI_SSID:-}" ]; then
  warn "WIFI_SSID empty in config.env — skipping WiFi setup (host uses wired)."
  exit 0
fi

# -----------------------------------------------------------------------------
# 1. Resolve the wlan interface.
# -----------------------------------------------------------------------------
if [ "${WIFI_IFACE:-auto}" = "auto" ]; then
  WIFI_IFACE=""
  for _if in /sys/class/net/wl*; do
    [ -e "$_if" ] || continue
    WIFI_IFACE="$(basename "$_if")"; break
  done
  [ -n "$WIFI_IFACE" ] || die "No wlan interface found. Missing firmware/driver? (see 00/01 WIFI_FIRMWARE_PKG)"
fi
set_kv WIFI_IFACE "$WIFI_IFACE"
log "WiFi interface: $WIFI_IFACE"

# Sanity: firmware present? If the NIC has no driver bound, warn loudly.
if ! iw dev "$WIFI_IFACE" info >/dev/null 2>&1; then
  warn "iw can't query $WIFI_IFACE — firmware/driver may be missing."
fi

# -----------------------------------------------------------------------------
# 2. Regulatory domain.
# -----------------------------------------------------------------------------
iw reg set "${WIFI_COUNTRY:-00}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 3. wpa_supplicant.conf — PSK hashed, never plaintext. chmod 600.
#    wpa_passphrase emits a network{} block with psk=<hash>. We strip the
#    commented plaintext line it adds for safety.
# -----------------------------------------------------------------------------
WPA_DIR="/etc/wpa_supplicant"
WPA_CONF="$WPA_DIR/wpa_supplicant.conf"
mkdir -p "$WPA_DIR"
log "Writing $WPA_CONF (PSK hashed) ..."
{
  echo "ctrl_interface=/var/run/wpa_supplicant"
  # netdev, not wheel: lets the unprivileged kiosk manage networks with wpa_cli
  # (the Super+w "add Wi-Fi" helper) without granting any wheel/sudo privilege.
  echo "ctrl_interface_group=netdev"
  echo "country=${WIFI_COUNTRY:-00}"
  echo "update_config=1"
  # STABLE MAC (critical for captive portals): a captive portal authorizes the
  # client MAC after browser login. If the MAC randomizes, the portal session is
  # lost on every (re)association and you'd have to log in constantly. Force the
  # permanent hardware MAC so the Entra-portal session persists for all VMs
  # (they NAT out this single MAC). See host/captive-portal.sh.
  echo "mac_addr=0"
  echo "preassoc_mac_addr=0"
  if [ -n "${WIFI_PSK:-}" ]; then
    # Hash PSK; drop the plaintext "#psk=..." comment line wpa_passphrase adds.
    wpa_passphrase "$WIFI_SSID" "$WIFI_PSK" | grep -v '^\s*#psk='
  else
    # Open network (no PSK).
    printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$WIFI_SSID"
  fi
} > "$WPA_CONF"
chmod 600 "$WPA_CONF"

# -----------------------------------------------------------------------------
# 4. /etc/network/interfaces — wlan via dhcp, launching wpa_supplicant.
#    Idempotent: replace any existing stanza for this iface.
# -----------------------------------------------------------------------------
IF_FILE="/etc/network/interfaces"
touch "$IF_FILE"
log "Configuring $IF_FILE for $WIFI_IFACE ..."
# Remove any prior auto/iface lines for this iface (simple stanza strip).
awk -v ifc="$WIFI_IFACE" '
  $0 ~ ("^auto[ \t]+" ifc "$")  {skip=1; next}
  $0 ~ ("^iface[ \t]+" ifc "[ \t]") {skip=1; next}
  /^auto|^iface/ {skip=0}
  skip==1 && /^[ \t]/ {next}
  skip==1 {skip=0}
  {print}
' "$IF_FILE" > "$IF_FILE.tmp" && mv "$IF_FILE.tmp" "$IF_FILE"

cat >> "$IF_FILE" <<EOF

auto $WIFI_IFACE
iface $WIFI_IFACE inet dhcp
    pre-up wpa_supplicant -B -i $WIFI_IFACE -c $WPA_CONF -Dnl80211,wext
    post-down killall -q wpa_supplicant || true
EOF

# -----------------------------------------------------------------------------
# 5. Enable services at boot (OpenRC / systemd).
# -----------------------------------------------------------------------------
if command -v rc-update >/dev/null 2>&1; then
  rc-update add wpa_supplicant boot 2>/dev/null || true
  rc-update add networking boot 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
  systemctl enable wpa_supplicant 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 6. Bring it up now.
# -----------------------------------------------------------------------------
log "Bringing up $WIFI_IFACE ..."
if command -v ifup >/dev/null 2>&1; then
  ifdown "$WIFI_IFACE" 2>/dev/null || true
  ifup "$WIFI_IFACE" 2>/dev/null || warn "ifup failed; check dmesg / firmware."
fi

# Deliberately DO NOT pin WAN_IFACE to the wlan here. A machine configured for
# Wi-Fi but actually running on ETHERNET (very common) would then NAT the guests
# out a dead wireless interface and they'd have no internet. isolate resolves the
# real uplink itself from the default route (`ip route get 1.1.1.1`) whenever
# WAN_IFACE is "auto" (the default) — Wi-Fi picks wlan, Ethernet picks eth. An
# operator who wants to force one still sets WAN_IFACE explicitly in config.env;
# wifi has no business overriding that.

# -----------------------------------------------------------------------------
# 7. Verify connectivity (best-effort).
# -----------------------------------------------------------------------------
sleep 5
if ip route show default 2>/dev/null | grep -q "$WIFI_IFACE"; then
  ok "Default route via $WIFI_IFACE."
else
  warn "No default route via $WIFI_IFACE yet (association/DHCP may be pending)."
fi
if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
  ok "Host internet OK over WiFi."
else
  warn "Host cannot reach internet yet. Check SSID/PSK, signal, firmware."
fi

cat <<EOF

WiFi configured. Uplink=$WIFI_IFACE. Next: create the VMs, then isolate (so NAT
+ inter-VM DROP rules bind to $WIFI_IFACE):
    cd /opt/appliance && ./setup.sh      # 1) create   2) isolate
EOF
;;
captive-portal)
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
# BOOTSTRAP ORDER (important): the portal must be cleared BEFORE creating the VMs
#   — their cloud-init needs internet on first boot:
#     operator: Super+p (portal login) -> ./setup.sh 1 (create) -> ./setup.sh 2 (isolate)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root
load_config
# Provision the audit log and the root-owned drop directory while we are root,
# so the kiosk-run helper written below has somewhere to record its login.
audit_init

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
# A portal login is an authentication event, so CONTRACT B wants it in the audit
# log — but this helper runs as the UNPRIVILEGED kiosk user, which must not be
# able to write (or even read) a 0600 root-owned log. Rather than widen the log
# or give the desktop a privilege, we reuse audit_event() from the shared
# library: for a non-root caller it drops the event into the root-owned,
# unreadable spool directory (mode 1733) and the next root-run audit_event folds
# it into the log. Nothing here needs root and nothing here can read the log.
AUDIT_LIB="$HERE/lib.sh"
EOF
cat >> "$PORTAL_SH" <<'EOF'
[ -r "$AUDIT_LIB" ] && . "$AUDIT_LIB"
# An appliance whose /opt tree moved must still be able to log in to the WiFi.
command -v audit_event >/dev/null 2>&1 || audit_event() { :; }

# Are we already online (portal cleared)?
code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$PROBE" || echo 000)"
if [ "$code" = "204" ]; then
  audit_event portal-login result=already-online
  notify_ok() { command -v i3-nagbar >/dev/null 2>&1 && \
    i3-nagbar -t warning -m "Already online — no portal login needed." & }
  notify_ok
  exit 0
fi

# Find the URL the portal redirects us to (the Entra login entry point).
portal_url="$(curl -s -o /dev/null -w '%{redirect_url}' -m 5 "$PROBE" || true)"
# The redirect target is chosen by WHOEVER runs the network — treat it as hostile
# input. Only ever hand the browser an http/https URL: reject file:, data:,
# javascript:, or anything with shell/space metacharacters, so a malicious portal
# cannot turn this launch into local-file access or argument injection into the
# kiosk browser (T-04 / SO-2). A rejected target falls back to the neverssl probe.
case "$portal_url" in
  http://*|https://*)
    case "$portal_url" in *[!A-Za-z0-9._~:/?#@!\$\&\'\(\)\*\+,\;=%-]*) portal_url="" ;; esac ;;
  *) portal_url="" ;;
esac
if [ -n "$portal_url" ]; then
  result=opened
else
  portal_url="http://neverssl.com"   # forces a redirect
  result=no-portal-found
fi

# Log BEFORE exec: exec replaces this process, so anything after it never runs.
audit_event portal-login "result=$result"

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

Bootstrap: do the portal login BEFORE ./src/environments.sh create (guests need internet
for cloud-init on first boot).
EOF
;;
install-to-disk)
# =============================================================================
# installer/install-to-disk.sh
# -----------------------------------------------------------------------------
# Install the appliance from the USB (live boot) onto the machine's INTERNAL
# disk, wiping it. After this, the machine boots the appliance from its own disk
# and the VMs live on the full-size internal drive.
#
# Uses Alpine's `setup-disk -m sys` which: partitions the target (GPT + EFI
# System Partition on UEFI), installs GRUB, and copies the running system —
# including /opt/appliance, the first-boot service, autologin, everything.
#
# DESTRUCTIVE: the selected internal disk is ERASED. You confirmed: wipe it,
# appliance only. This script still asks once before erasing.
#
# RUN THIS FROM THE USB LIVE BOOT, then reboot and remove the USB.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root
require_cmds dd lsblk findmnt growpart resize2fs

# config.env carries the install choices (ENCRYPT, LUKS_PASS). Tolerate its
# absence (BAKE_CONFIG=0 images): the defaults below then give the plain
# dd-clone. load_config is NOT used — it would die on a config-less image.
# shellcheck disable=SC1090
[ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV"

# -----------------------------------------------------------------------------
# 1. Identify the disk we are BOOTED FROM (the USB) so we never target it.
# -----------------------------------------------------------------------------
root_src="$(findmnt -no SOURCE / || true)"          # e.g. /dev/sdb2 or /dev/sda2
# Strip partition suffix to get the parent disk (sdb2->sdb, nvme0n1p2->nvme0n1).
usb_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)"
[ -n "$usb_disk" ] || usb_disk="$(echo "$root_src" | sed -E 's|/dev/||; s|p?[0-9]+$||')"
log "Booted from (USB, will NOT touch): /dev/$usb_disk"

# -----------------------------------------------------------------------------
# 2. Pick the INTERNAL disk by TRANSPORT + HOTPLUG, never by size.
#    Size is a bad discriminator: the boot USB itself can be the largest disk
#    (a 1 TB stick), and an external backup drive can be larger than the internal
#    SSD — so "largest" happily targets the wrong device. The RM flag is no good
#    either (many USB/external disks report RM=0). A disk is INTERNAL when its
#    transport is not usb AND it is not hot-pluggable (nvme/sata/ata/virtio/mmc
#    qualify; USB sticks and external drives are hotplug=1 and/or tran=usb). Size
#    is used ONLY to break ties between genuine internal disks. If transport info
#    is somehow unavailable, fall back to the largest non-removable disk + warn.
# -----------------------------------------------------------------------------
log "Block devices:"
lsblk -dno NAME,SIZE,TYPE,TRAN,HOTPLUG,MODEL | sed 's/^/    /'

target=""; best_bytes=0
fallback=""; fb_bytes=0
while read -r name type rm hotplug tran; do
  [ "$type" = "disk" ] || continue
  [ "$name" = "$usb_disk" ] && continue            # never the boot/USB disk
  case "$name" in loop*|ram*|zram*|sr*|fd*|md*) continue ;; esac
  bytes="$(lsblk -dnbo SIZE "/dev/$name" 2>/dev/null | head -1)"
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  if [ "$tran" != "usb" ] && [ "${hotplug:-0}" = "0" ]; then
    # genuine internal disk (fixed, non-usb transport)
    [ "$bytes" -gt "$best_bytes" ] && { best_bytes="$bytes"; target="$name"; }
  elif [ "$rm" = "0" ]; then
    # usb/hotpluggable but marked non-removable: fallback only
    [ "$bytes" -gt "$fb_bytes" ] && { fb_bytes="$bytes"; fallback="$name"; }
  fi
done <<EOF
$(lsblk -dno NAME,TYPE,RM,HOTPLUG,TRAN)
EOF
if [ -z "$target" ] && [ -n "$fallback" ]; then
  warn "No disk identified as INTERNAL by transport/hotplug — falling back to the largest non-removable disk (/dev/$fallback). VERIFY this is the internal disk, or set TARGET_DISK=<name>."
  target="$fallback"
fi

# Allow override: TARGET_DISK=nvme0n1 ./src/host.sh install-to-disk
target="${TARGET_DISK:-$target}"
[ -n "$target" ] || die "No internal disk found. Set TARGET_DISK=<name> explicitly."
tgt_size="$(lsblk -dno SIZE "/dev/$target" | head -1)"
log "Selected INTERNAL disk to install onto: /dev/$target ($tgt_size)"

# -----------------------------------------------------------------------------
# 3. Confirm the wipe.
#    Interactive: type the disk name to proceed.
#    AUTO_CONFIRM=1 (used by the USB auto-installer): 10s countdown to abort,
#    then proceed automatically. This is what makes the USB a hands-off installer.
# -----------------------------------------------------------------------------
warn "This will ERASE ALL DATA on /dev/$target and install the appliance."
if [ "${AUTO_CONFIRM:-0}" = "1" ]; then
  warn "AUTO-INSTALL in 10s. Press Ctrl+C now to abort."
  i=10
  while [ "$i" -gt 0 ]; do printf '\r  erasing /dev/%s in %2ds ...' "$target" "$i"; sleep 1; i=$((i-1)); done
  printf '\n'
else
  printf 'Type the disk name (%s) to proceed: ' "$target"
  read -r ans
  [ "$ans" = "$target" ] || die "Confirmation mismatch; aborting (nothing erased)."
fi

# -----------------------------------------------------------------------------
# 4. Install by CLONING the USB image to the internal disk (dd), then growing
#    the root partition to fill the disk.
#
#    WHY NOT setup-disk: setup-disk re-installs packages from apk repos onto the
#    target — it does NOT copy our baked rootfs. With no network / community repo
#    during auto-install, all community packages (xkbcomp, xinit, i3wm, xterm,
#    virt-viewer, firefox) fail ("no such package required by world"), leaving X
#    with no keymap (dead keyboard in i3) and a broken desktop. Cloning the whole
#    device guarantees the internal disk is byte-identical to the tested USB —
#    every package, config, and the bootloader come along, no apk, no network.
# -----------------------------------------------------------------------------
# Partition suffix differs: sdX -> sdX2 ; nvme0n1 -> nvme0n1p2 ; mmcblk0 -> p2.
partsuffix() { case "$1" in *[0-9]) echo "p";; *) echo "";; esac; }
usb_p="$(partsuffix "$usb_disk")"
tgt_p="$(partsuffix "$target")"

# --- SAFETY GUARDS: never write the wrong direction ---------------------------
# Source = the disk we booted from (USB). Dest = the internal target.
src_bytes="$(lsblk -dnbo SIZE "/dev/$usb_disk" | head -1)"
dst_bytes="$(lsblk -dnbo SIZE "/dev/$target"   | head -1)"
[ "$usb_disk" != "$target" ] || die "SOURCE == DEST ($usb_disk); aborting (would clone a disk onto itself)."
# Guard the DIRECTION by transport, NOT by size. A size test false-positives when
# the boot USB is bigger than the internal disk (e.g. a 1 TB stick onto a 512 GB
# SSD) and needlessly refuses a correct install. Instead: refuse only if the
# TARGET itself is usb/hot-pluggable — i.e. we'd be cloning ONTO a removable disk.
tgt_tran="$(lsblk -dno TRAN "/dev/$target" 2>/dev/null | head -1)"
tgt_hotplug="$(lsblk -dno HOTPLUG "/dev/$target" 2>/dev/null | head -1)"
if [ "${FORCE_DIRECTION:-0}" != "1" ] && { [ "$tgt_tran" = "usb" ] || [ "${tgt_hotplug:-0}" = "1" ]; }; then
  die "Refusing: target /dev/$target is USB/hot-pluggable (transport=${tgt_tran:-?}, hotplug=${tgt_hotplug:-?}), not an internal disk. Set TARGET_DISK=<internal disk>, or FORCE_DIRECTION=1 to override."
fi
log "CLONE DIRECTION -> SOURCE=/dev/$usb_disk (boot/USB, $((src_bytes/1024/1024/1024))G)  DEST=/dev/$target (internal, $((dst_bytes/1024/1024/1024))G)"

if [ "${ENCRYPT:-0}" = "1" ]; then
  # ===========================================================================
  # ENCRYPTED install (LUKS2, passphrase at boot). EXPERIMENTAL — test on a
  # spare/VM first; a bad encrypted install can leave the disk unbootable.
  # File-copy (not dd) into a LUKS container: ESP stays plaintext (GRUB+kernel
  # +initramfs), root is encrypted; the Alpine initramfs prompts for the
  # passphrase at boot, unlocks, mounts root. TPM2 auto-unlock is a follow-up
  # (needs a custom mkinitfs/clevis hook — not done here).
  # Requires LUKS_PASS set in config.env (used non-interactively).
  # ===========================================================================
  require_cmds cryptsetup mkfs.ext4 mkfs.vfat blkid grub-install
  # The passphrase must be explicit in config.env — secrets are never
  # auto-generated (a generated LUKS passphrase the operator never recorded
  # makes the disk unrecoverable).
  [ -n "${LUKS_PASS:-}" ] && [ "${LUKS_PASS:-}" != "generate" ] || \
    die "ENCRYPT=1 but LUKS_PASS is not set in config.env. Set an explicit passphrase — secrets are never auto-generated."
  esp="/dev/${target}${tgt_p}1"; luks="/dev/${target}${tgt_p}2"
  log "Partitioning /dev/$target (ESP + LUKS) ..."
  sgdisk --zap-all "/dev/$target"
  sgdisk -n1:0:+512M -t1:ef00 -c1:efi -n2:0:0 -t2:8309 -c2:cryptroot "/dev/$target"
  partprobe "/dev/$target"; partx -u "/dev/$target" 2>/dev/null || true; sleep 1
  mkfs.vfat -F32 "$esp" >/dev/null
  log "Creating LUKS2 container (this reformats $luks) ..."
  printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$luks" -
  printf '%s' "$LUKS_PASS" | cryptsetup open "$luks" cryptroot -
  mkfs.ext4 -q -F /dev/mapper/cryptroot
  mkdir -p /mnt/src /mnt/dst
  log "Copying root filesystem from USB into the encrypted volume ..."
  mount /dev/mapper/cryptroot /mnt/dst
  # The USB root IS the running / — ext4 refuses a second mount of it ("already
  # mounted on /", "would change RO state"), so stream it with tar instead,
  # excluding the pseudo-filesystems and /mnt itself (the destination is under
  # it — copying it would recurse).
  ( cd / && tar cf - \
      --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
      --exclude=./mnt --exclude=./media --exclude=./tmp . ) \
    | tar xf - -C /mnt/dst
  mkdir -p /mnt/dst/proc /mnt/dst/sys /mnt/dst/dev /mnt/dst/run /mnt/dst/mnt /mnt/dst/media
  mkdir -p /mnt/dst/tmp && chmod 1777 /mnt/dst/tmp
  log "Copying ESP (kernel/initramfs/grub) ..."
  mount "$esp" /mnt/dst/boot 2>/dev/null || { mkdir -p /mnt/dst/boot; mount "$esp" /mnt/dst/boot; }
  # Same story for the ESP: it is already mounted at /boot on the running USB.
  if mount -o ro "/dev/${usb_disk}${usb_p}1" /mnt/src 2>/dev/null; then
    cp -a /mnt/src/. /mnt/dst/boot/
    umount /mnt/src
  else
    cp -a /boot/. /mnt/dst/boot/
  fi
  luuid="$(blkid -s UUID -o value "$luks")"
  espuuid="$(blkid -s UUID -o value "$esp")"
  # initramfs must include cryptsetup so it can unlock root at boot — and the
  # storage driver the ROOT device sits on: virtio covers VMs, but real laptops
  # boot from NVMe (and some from eMMC/SD). Without nvme the LUKS device never
  # appears and the boot dies with "mounting /dev/mapper/cryptroot on /sysroot
  # failed: No such file or directory" right after (or instead of) the prompt.
  # Keyboard at the passphrase prompt: PS/2 (i8042/atkbd) is built into the
  # kernel and USB HID comes with the usb feature, but a keyboard behind the
  # I2C bus (some AMD/Intel ultrabooks) needs i2c-hid — nothing else pulls it
  # in, and a dead keyboard at the prompt looks exactly like "the passphrase
  # is rejected".
  cat > /mnt/dst/etc/mkinitfs/features.d/i2chid.modules <<'I2C'
kernel/drivers/i2c/busses/i2c-piix4.ko*
kernel/drivers/i2c/busses/i2c-i801.ko*
kernel/drivers/hid/i2c-hid
kernel/drivers/hid/hid-generic.ko*
I2C
  echo 'features="ata base ide scsi usb virtio nvme mmc ext4 cryptsetup keymap i2chid"' > /mnt/dst/etc/mkinitfs/mkinitfs.conf
  cat > /mnt/dst/etc/fstab <<F
/dev/mapper/cryptroot / ext4 rw,relatime 0 1
UUID=$espuuid /boot vfat rw,relatime 0 2
F
  cat > /mnt/dst/etc/default/grub <<G
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR="Appliance"
GRUB_CMDLINE_LINUX_DEFAULT="cryptroot=UUID=$luuid cryptdm=cryptroot modules=ext4 i8042.nomux i8042.noloop console=tty0 quiet"
GRUB_CMDLINE_LINUX="root=/dev/mapper/cryptroot"
GRUB_ENABLE_CRYPTODISK=n
# Text console, not gfxterm: the mkconfig-generated gfxterm renders a BLACK
# screen on real firmware and OVMF alike (the machine looks dead before the
# kernel ever starts). The USB image's hand-written grub.cfg is console-mode
# for the same reason.
GRUB_TERMINAL=console
G
  for d in dev proc sys; do mount --bind "/$d" "/mnt/dst/$d"; done
  kver="$(ls /mnt/dst/lib/modules | head -1)"
  chroot /mnt/dst mkinitfs "$kver" 2>/dev/null || chroot /mnt/dst mkinitfs
  chroot /mnt/dst grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable --no-nvram 2>/dev/null || warn "grub-install warned"
  chroot /mnt/dst grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "grub-mkconfig warned"
  touch /mnt/dst/opt/appliance/.installed-system
  # Preserve a baked config.env (.config-baked marker); otherwise wipe for fresh detect.
  [ -f /mnt/dst/opt/appliance/.config-baked ] || rm -f /mnt/dst/opt/appliance/config.env
  rm -f /mnt/dst/opt/appliance/.firstboot-done
  for d in dev proc sys; do umount "/mnt/dst/$d"; done
  umount /mnt/dst/boot; umount /mnt/dst
  cryptsetup close cryptroot
  ok "ENCRYPTED install complete (LUKS2). You'll enter the passphrase at each boot."
else
  # --- Default: unencrypted dd-clone (fast, byte-identical to the tested USB) --
  # Copy ONLY the used extent, not the whole physical USB. The flashed image is
  # only IMG_SIZE (~4G): its GPT + partitions live in the first ~4G and the rest
  # of a larger stick is empty. dd'ing the whole device to EOF would both waste
  # time and — critically — FAIL with ENOSPC when the USB is bigger than the
  # target internal disk (e.g. 64G stick -> 32G eMMC), leaving it unbootable.
  # Bound the copy to (last-partition end + secondary GPT), rounded up to bs.
  ddcount=""
  last_end="$(partx -g -o END "/dev/$usb_disk" 2>/dev/null | tr -d ' ' | sort -n | tail -1)"
  if [ -n "$last_end" ] && [ "$last_end" -gt 0 ] 2>/dev/null; then
    copy_bytes=$(( (last_end + 1 + 33) * 512 ))          # +33 sectors = backup GPT
    count=$(( (copy_bytes + 4194304 - 1) / 4194304 ))    # ceil to 4MiB blocks
    ddcount="count=$count"
    log "Cloning ~$(( count * 4 ))MiB (used extent) /dev/$usb_disk -> /dev/$target ..."
  else
    warn "Could not determine used extent; cloning the whole USB device (may be slow / may not fit)."
    log "Cloning /dev/$usb_disk -> /dev/$target ..."
  fi
  sync
  # NOTE: busybox dd (Alpine) does NOT support status=progress — it would fail
  # immediately. Run dd in the background with a dot heartbeat; capture errors.
  # shellcheck disable=SC2086  # $ddcount is an intentional single word or empty
  dd if="/dev/$usb_disk" of="/dev/$target" bs=4M $ddcount conv=fsync 2>/tmp/dd.err &
  ddpid=$!
  while kill -0 "$ddpid" 2>/dev/null; do printf '.'; sleep 2; done
  printf '\n'
  wait "$ddpid" || { warn "dd stderr:"; cat /tmp/dd.err >&2; die "dd clone failed."; }
  sync
  # growpart relocates the backup GPT + resizes root part #2 to fill the disk.
  root_part="/dev/${target}${tgt_p}2"
  if command -v growpart >/dev/null 2>&1; then
    growpart "/dev/$target" 2 2>&1 | tail -1 || warn "growpart failed; root stays USB-sized."
    partprobe "/dev/$target" 2>/dev/null || true
    partx -u "/dev/$target" 2>/dev/null || true
    sleep 1
    e2fsck -fy "$root_part" 2>/dev/null || true
    resize2fs "$root_part" 2>/dev/null || warn "resize2fs failed; root stays USB-sized (still bootable)."
  else
    warn "growpart missing; root stays USB-sized (still bootable, just not grown)."
  fi
  ok "Appliance cloned to /dev/$target."
  # Mark as INSTALLED so first boot PROVISIONS instead of re-running the installer.
  if mount "$root_part" /mnt 2>/dev/null; then
    mkdir -p /mnt/opt/appliance && touch /mnt/opt/appliance/.installed-system 2>/dev/null || true
    # Wipe config.env so the installed system re-detects fresh — UNLESS it was
    # baked from a local config (make-image drops .config-baked), which the
    # operator wants preserved on the installed appliance.
    [ -f /mnt/opt/appliance/.config-baked ] || rm -f /mnt/opt/appliance/config.env 2>/dev/null || true
    rm -f /mnt/opt/appliance/.firstboot-done 2>/dev/null || true
    umount /mnt 2>/dev/null || true
  fi
fi

if [ "${AUTO_CONFIRM:-0}" = "1" ]; then
  warn "Install complete. Powering off in 8s — REMOVE THE USB before powering back on."
  sleep 8
  poweroff
else
  cat <<EOF

DONE. Now:
  1. Poweroff:            poweroff
  2. Remove the USB stick.
  3. Power on — the machine boots the appliance from its internal disk.
  4. First boot auto-configures the host base (detect, configure, harden,
     switching, Wi-Fi, portal) with the FULL disk available, so the per-env
     resource split is sized to the real machine. Then, as ROOT on tty2
     (Ctrl+Alt+F2 — the host has no sudo by design), create the VMs:
        cd /opt/appliance && ./setup.sh     # 1) create   2) isolate + verify
EOF
fi
;;
isolation-watch)
# =============================================================================
# host/isolation-watch.sh
# -----------------------------------------------------------------------------
# Continuous assurance that the environments are STILL isolated.
#
# environments/isolate.sh proves isolation once, at setup, and exits. After that
# nothing ever looks again: a ruleset can be flushed, a libvirt network
# redefined, a script half re-run — and the machine keeps presenting three
# environments that no longer have a fence between them. This is the recurring
# check. It recomputes the ordered environment pairs from $ENVS, asserts every
# one of them still has a live DROP rule in the kernel, and publishes the
# verdict so "is it still isolated?" can be answered at any instant instead of
# only by re-running setup and reading the output.
#
# Host-side only, no guest agent: isolate.sh section 3b already establishes that
# the ruleset assertion alone is conclusive for the cross-environment fence, and
# it costs milliseconds — cheap enough to run every minute, and it works while
# the guests are still booting or powered off.
#
#   host/isolation-watch.sh [--once] [-v]   run one check (--once is the default)
#   host/isolation-watch.sh --install-timer install/refresh the recurring check
#
# Exit status: 0 = OK, 1 = FAIL (isolation is broken), 2 = UNKNOWN (could not
# determine — treat as "nobody can currently vouch for this machine").
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

# CONTRACT A: tmpfs status file, one TAB-separated line "STATE EPOCH DETAIL".
STATUS_DIR="/run/appliance"
STATUS_FILE="$STATUS_DIR/isolation.status"
# The lock lives beside it on the same tmpfs, so a lock can never survive a
# reboot and wedge the watch on a machine that came back up.
LOCK_DIR="$STATUS_DIR/isolation-watch.lock"
# CONTRACT B: append-only audit log, 0600 root:root.
AUDIT_LOG="/var/log/appliance-audit.log"

MODE="once"
VERBOSE=0
# A human at a console expects an answer; cron does not. Being chatty by default
# would put a line a minute into the appliance's logs and drown the one that
# matters, so the steady-state OK is silent unless someone is watching.
if [ -t 2 ]; then VERBOSE=1; fi

for _arg in "$@"; do
  case "$_arg" in
    --once)          MODE="once" ;;
    --install-timer) MODE="install-timer" ;;
    -v|--verbose)    VERBOSE=1 ;;
    -h|--help)
      sed -n '3,24p' "$0" >&2; exit 0 ;;
    *) die "Unknown argument '$_arg' (use --once, --install-timer, -v)." ;;
  esac
done

LOCK_HELD=0
CHECKING=0
EMITTED=0

# --- CONTRACT A -------------------------------------------------------------
# Atomic write: a reader (the trust bar, an operator, a later health endpoint)
# must never catch a half-written line, and two watchers must never interleave
# their bytes. Temp file + rename inside the same tmpfs directory guarantees a
# reader sees either the old line or the new one, never a splice of both.
write_status() {
  _st="$1"
  # DETAIL is one line by contract; fold anything that could break the format.
  _dt="$(printf '%s' "$2" | tr '\n\t' '  ')"
  mkdir -p "$STATUS_DIR" 2>/dev/null || true
  _tmp="$STATUS_FILE.$$"
  if printf '%s\t%s\t%s\n' "$_st" "$(date +%s)" "$_dt" > "$_tmp" 2>/dev/null; then
    chmod 644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$_tmp"
  fi
  EMITTED=1
}

# CONTRACT A also binds readers: a missing or unparsable file is UNKNOWN and
# must never crash the reader. This script is one of its own readers — it needs
# the previous verdict to decide whether the state CHANGED — so it obeys the
# same rule. After a reboot /run is a fresh tmpfs and the file is simply gone,
# which is exactly what we want: UNKNOWN until the first check of this boot,
# never a stale OK inherited from the last one.
prev_state() {
  _s=""
  if [ -r "$STATUS_FILE" ]; then
    _s="$(head -n1 "$STATUS_FILE" 2>/dev/null | cut -f1)" || _s=""
  fi
  case "$_s" in
    OK|FAIL|UNKNOWN) printf '%s' "$_s" ;;
    *)               printf 'UNKNOWN' ;;
  esac
}

# --- CONTRACT B -------------------------------------------------------------
# One event per line, "<ISO8601-UTC> <event> <key=value>...". A short line
# written with a single append to an O_APPEND descriptor is atomic, so parallel
# writers (this watch, the switcher, the USB router) cannot tear each other's
# lines. Values are space-free tokens by construction and never carry a secret.
audit() {
  ( umask 077; touch "$AUDIT_LOG" ) 2>/dev/null || true
  # Self-heal the mode: this log names which environment lost its fence and
  # when. The unprivileged kiosk desktop user must not be able to read it, and
  # certainly not to append a reassuring forgery.
  chmod 600 "$AUDIT_LOG" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$AUDIT_LOG" 2>/dev/null || true
}

# record STATE DETAIL [KEY=VALUE ...] — publish CONTRACT A always, append
# CONTRACT B only when the STATE actually changed. Running once a minute, an
# unconditional append would bury the single line that matters (the transition)
# under 1440 identical lines a day.
record() {
  _st="$1"; _dt="$2"; shift 2
  _prev="$(prev_state)"
  write_status "$_st" "$_dt"
  if [ "$_st" != "$_prev" ]; then
    if [ "$#" -gt 0 ]; then
      audit "isolation-check state=$_st prev=$_prev $*"
    else
      audit "isolation-check state=$_st prev=$_prev"
    fi
  fi
}

# --- concurrency -------------------------------------------------------------
# The cron tick and an operator typing the command can land at the same instant.
# Both would read-previous-then-write-new and could log the same transition
# twice. mkdir is atomic on every filesystem we care about and needs no flock
# (busybox has no flock built in).
acquire_lock() {
  # mkdir is not recursive: on a fresh boot /run/appliance does not exist yet,
  # and without its parent the lock can never be taken — the first check of
  # every boot would report "another check is running" and exit UNKNOWN.
  mkdir -p "$STATUS_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then return 0; fi
  # Reap a lock left by an instance that was killed outright: without this the
  # watch wedges forever and the status file freezes at whatever it last said —
  # very likely a stale OK, which is the precise failure this script exists to
  # prevent. Failing open on the lock is safe; failing open on the verdict isn't.
  _now="$(date +%s)"
  _born="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || printf '%s' "$_now")"
  if [ "$((_now - _born))" -gt "${ISOLATION_WATCH_LOCK_STALE:-300}" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then return 0; fi
  fi
  return 1
}

cleanup() {
  _rc=$?
  if [ "$LOCK_HELD" = "1" ]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
  # Fail closed. If we got as far as starting a check but never reached a
  # verdict (nft missing, config unreadable, killed mid-run), the status file
  # must not be left asserting the previous run's OK. UNKNOWN is the honest
  # answer and readers already know how to treat it.
  if [ "$CHECKING" = "1" ] && [ "$EMITTED" = "0" ]; then
    record UNKNOWN "check aborted before a verdict (rc=$_rc)" "reason=aborted"
  fi
  return 0
}
trap cleanup EXIT

# The pair grep is the security-critical comparison in this script: anchor it on
# literal addresses so a dot cannot wildcard 10.10.1.0 onto a lookalike subnet.
esc_re() { printf '%s' "$1" | sed 's/[.]/\\./g'; }

# -----------------------------------------------------------------------------
# The check.
# -----------------------------------------------------------------------------
run_check() {
  if ! acquire_lock; then
    # Another check is already in flight; its verdict will be at least as fresh
    # as ours. Report what is on file rather than racing it into the audit log.
    _s="$(prev_state)"
    if [ "$VERBOSE" = "1" ]; then log "another isolation check is running; last recorded state: $_s"; fi
    case "$_s" in OK) exit 0 ;; FAIL) exit 1 ;; *) exit 2 ;; esac
  fi
  LOCK_HELD=1
  CHECKING=1
  require_cmds nft

  # ALL defined environment positions, enabled or not — the same superset
  # isolate.sh builds its DROP rules over, and for the same reason: an
  # environment that was created and then disabled keeps its libvirt network and
  # possibly a running VM, so it must stay fenced. Checking only the enabled
  # ones would call that machine isolated when it is not.
  _pos=""; _n=0
  for _e in ${ENVS:-}; do
    _n=$((_n + 1))
    _pos="$_pos $_e:$_n"
  done
  _total=$((_n * (_n - 1)))

  if [ "$_n" -eq 0 ]; then
    # No environment model at all — we cannot say anything about isolation, and
    # "nothing to check" must never be reported as OK.
    record UNKNOWN "ENVS is empty — no environment model to verify" "reason=no-envs"
    warn "ENVS is empty in config.env — isolation cannot be verified."
    exit 2
  fi

  # THE failure mode this watch exists for. With the table gone there are no
  # DROP rules to look for, and a pair loop over an absent table would count
  # zero present out of zero expected and cheerfully report OK on a wide-open
  # machine. Assert the table exists BEFORE looking at any pair.
  if ! _live="$(nft list table inet appliance_isol 2>/dev/null)"; then
    record FAIL "nftables table inet appliance_isol is absent (ruleset flushed?)" \
                "pairs=0/$_total missing=table"
    warn "Isolation table inet appliance_isol is GONE — run ./src/environments.sh isolate."
    exit 1
  fi

  _present=0; _missing=0; _first=""; _list=""
  for _a in $_pos; do
    _ea="${_a%:*}"; _ia="${_a#*:}"
    _ra="$(esc_re "$(env_subnet "$_ea" "$_ia").0/24")"
    for _b in $_pos; do
      [ "$_a" = "$_b" ] && continue
      _eb="${_b%:*}"; _ib="${_b#*:}"
      _rb="$(esc_re "$(env_subnet "$_eb" "$_ib").0/24")"
      if printf '%s\n' "$_live" | grep -q "ip saddr $_ra ip daddr $_rb .*drop"; then
        _present=$((_present + 1))
      else
        _missing=$((_missing + 1))
        [ -n "$_first" ] || _first="$_ea->$_eb"
        # Keep DETAIL to one readable line even when the whole fence is gone.
        if [ "$_missing" -le 4 ]; then _list="$_list $_ea->$_eb"; fi
      fi
    done
  done

  if [ "$_missing" -eq 0 ]; then
    record OK "$_present/$_total pairs" "pairs=$_present/$_total"
    if [ "$VERBOSE" = "1" ]; then ok "Isolation intact: $_present/$_total inter-env DROP rules live."; fi
    exit 0
  fi

  if [ "$_missing" -gt 4 ]; then _list="$_list (+$((_missing - 4)) more)"; fi
  record FAIL "$_present/$_total pairs; missing$_list" "pairs=$_present/$_total missing=$_first"
  # Worth stderr even unattended: on the appliance this is the first place an
  # operator looks after a boot that went wrong.
  warn "Isolation INCOMPLETE: $_missing/$_total inter-env DROP rule(s) missing —$_list"
  exit 1
}

# -----------------------------------------------------------------------------
# Timer installation.
#
# WHY cron on the appliance: OpenRC has no timer concept, and a supervised
# sleep-loop daemon would mean owning a PID file, restart policy and log
# rotation for a check that takes milliseconds. busybox crond is already on the
# box, already supervised by OpenRC, and re-reads /etc/crontabs every minute, so
# one crontab line is the entire mechanism — nothing to keep alive, nothing to
# leak. Its granularity is one minute, which is why the default interval is 60s;
# a shorter interval is rounded up to a minute there. On a systemd host (the
# Debian development path) we emit a real timer instead, which does honour
# sub-minute intervals.
#
# Both writers are idempotent: they remove whatever they installed before and
# put back exactly one entry, so re-running after an interval or path change
# leaves a single correct schedule rather than a second one alongside the first.
# -----------------------------------------------------------------------------
CRONTAB="/etc/crontabs/root"
SD_SERVICE="/etc/systemd/system/appliance-isolation-watch.service"
SD_TIMER="/etc/systemd/system/appliance-isolation-watch.timer"

remove_timer() {
  if [ -f "$CRONTAB" ] && grep -q 'isolation-watch' "$CRONTAB" 2>/dev/null; then
    _t="$CRONTAB.appliance.$$"
    ( umask 077; grep -v 'isolation-watch' "$CRONTAB" > "$_t" || true )
    mv -f "$_t" "$CRONTAB"
  fi
  if command -v systemctl >/dev/null 2>&1 && [ -f "$SD_TIMER" ]; then
    systemctl disable --now appliance-isolation-watch.timer 2>/dev/null || true
    rm -f "$SD_TIMER" "$SD_SERVICE"
    systemctl daemon-reload 2>/dev/null || true
  fi
}

install_timer() {
  _self="$HERE/host.sh isolation-watch"
  _iv="${ISOLATION_WATCH_INTERVAL:-60}"
  case "$_iv" in
    ''|*[!0-9]*) die "ISOLATION_WATCH_INTERVAL must be a whole number of seconds (got '$_iv')." ;;
  esac
  [ "$_iv" -ge 1 ] || die "ISOLATION_WATCH_INTERVAL must be at least 1 second."

  if [ "${ISOLATION_WATCH:-1}" = "0" ]; then
    remove_timer
    warn "ISOLATION_WATCH=0 — recurring isolation check NOT installed. Nothing will notice if the ruleset is flushed after setup."
    return 0
  fi

  # OpenRC first, matching every other service-touching script in this tree.
  if command -v rc-update >/dev/null 2>&1; then
    _min=$(( (_iv + 59) / 60 ))
    if [ "$_min" -lt 1 ];  then _min=1;  fi
    # "*/60" is not a legal minute field; an hour is cron's practical floor here.
    if [ "$_min" -gt 59 ]; then _min=59; fi
    if [ "$_min" -eq 1 ]; then _spec="* * * * *"; else _spec="*/$_min * * * *"; fi

    mkdir -p /etc/crontabs
    ( umask 077; touch "$CRONTAB" )
    _t="$CRONTAB.appliance.$$"
    # The check's output IS the status file and the audit log, so send the
    # stream to /dev/null: crond would otherwise mail or syslog a line a minute.
    ( umask 077
      grep -v 'isolation-watch' "$CRONTAB" > "$_t" 2>/dev/null || true
      printf '%s %s --once >/dev/null 2>&1\n' "$_spec" "$_self" >> "$_t" )
    chmod 600 "$_t"
    mv -f "$_t" "$CRONTAB"
    rc-update add crond default 2>/dev/null || true
    rc-service crond start >/dev/null 2>&1 || true
    ok "Recurring isolation check installed (crond, every ${_min} min) -> $STATUS_FILE"
    if [ "$_iv" -lt 60 ]; then
      warn "ISOLATION_WATCH_INTERVAL=${_iv}s rounded up to 60s: cron cannot schedule below one minute."
    fi
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system
    # Write through a temp file in the same directory so a concurrent
    # daemon-reload can never read a half-written unit.
    _t="$(mktemp /etc/systemd/system/.appliance-watch.XXXXXX)"
    cat > "$_t" <<EOF
[Unit]
Description=Verify inter-environment isolation is still enforced (appliance)

[Service]
Type=oneshot
ExecStart=$_self --once
EOF
    chmod 644 "$_t"; mv -f "$_t" "$SD_SERVICE"
    _t="$(mktemp /etc/systemd/system/.appliance-watch.XXXXXX)"
    cat > "$_t" <<EOF
[Unit]
Description=Periodic inter-environment isolation check (appliance)

[Timer]
OnBootSec=30s
OnUnitActiveSec=${_iv}s
AccuracySec=1s
Unit=appliance-isolation-watch.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$_t"; mv -f "$_t" "$SD_TIMER"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now appliance-isolation-watch.timer 2>/dev/null || true
    ok "Recurring isolation check installed (systemd timer, every ${_iv}s) -> $STATUS_FILE"
    return 0
  fi

  warn "Neither OpenRC nor systemd found — no recurring isolation check installed. Run host/isolation-watch.sh --once from your own scheduler, or isolation is only ever verified at setup time."
}

require_root
load_config

case "$MODE" in
  install-timer) install_timer ;;
  *)             run_check ;;
esac
;;
usb-to-vm)
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
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# No require_root: the kiosk user is in the libvirt group and uses qemu:///system,
# so `virsh attach-device` works unprivileged. The udev path runs this as root,
# which also works. Either way we only touch libvirt, never usbguard IPC.
export LIBVIRT_DEFAULT_URI=qemu:///system
require_cmds virsh
# When udev triggers this on plug we are root, so provision the audit log and
# the kiosk-writable spool here: it makes the Super+y path (kiosk user) able to
# record its routes without anyone ever widening the 0600 log. No-op otherwise.
audit_init

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
# The detach is best-effort (libvirt errors when the device was not attached,
# which is the normal case), but the outcome is not: after this loop the device
# is attached to none of these environments, which is exactly what the audit
# record claims.
cleared=""
for e in $envs; do
  [ "$e" = "$target" ] && continue
  hostdev | virsh detach-device "$e" /dev/stdin --live 2>/dev/null || true
  cleared="${cleared:+$cleared,}$e"
done
if hostdev | virsh attach-device "$target" /dev/stdin --live; then
  # Peripheral compartmentalisation is an ANSSI control; the record of WHICH
  # environment got the device — and which ones it was taken away from — is the
  # part you need after an incident, so both go in one event, one line.
  audit_event usb-route "vendor=$vend" "product=$prod" "env=$target" \
              "detached=${cleared:--}" result=attached
  echo "YubiKey $vp -> $target"
else
  # A refused attach is just as interesting: it says the operator intended to
  # hand this key to that environment even though it did not happen.
  audit_event usb-route "vendor=$vend" "product=$prod" "env=$target" \
              "detached=${cleared:--}" result=attach-failed
  echo "Attach failed (is $target running?)"; sleep 3; exit 1
fi
sleep 1
;;
usb-allow)
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
if [ -f "$HERE/lib.sh" ]; then . "$HERE/lib.sh"
elif [ -f "$HERE/lib.sh" ]; then . "$HERE/lib.sh"
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
;;
secure-boot)
# =============================================================================
# host/secure-boot.sh   (ANSSI: démarrage sécurisé + mesuré + TPM)
# -----------------------------------------------------------------------------
# OPT-IN, EXPERIMENTAL, BRICK-PRONE. Enables UEFI Secure Boot with your OWN keys
# and TPM2-based measured boot / auto-unlock. Involves a MANUAL firmware step and
# can leave the machine unbootable if the firmware or key state is wrong. Test on
# a spare disk first. Nothing here runs unless you invoke this script.
#
# What it does:
#   1. sbctl: create a key set, sign GRUB + the kernel, and (if the firmware is
#      in Setup Mode) enroll the keys — so only your signed boot chain runs once
#      Secure Boot is turned on in BIOS.
#   2. TPM2 measured boot + auto-unlock of the LUKS root (if the disk is
#      encrypted): bind the LUKS volume to the TPM's PCRs with clevis, so the
#      disk unlocks automatically ONLY if the boot chain is unmodified (tamper =
#      no unlock). Falls back to the boot passphrase.
#
# Requires: UEFI, an installed (ENCRYPT=1) system for the TPM-unlock part, and
# network (installs sbctl / tpm2-tools / clevis on first run).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root

[ -d /sys/firmware/efi ] || die "Not booted in UEFI mode — Secure Boot needs UEFI."

warn "EXPERIMENTAL: Secure Boot / TPM misconfiguration can make the machine"
warn "UNBOOTABLE. Ensure you have recovery media + the LUKS passphrase recorded."
printf 'Type YES to proceed: '; read -r a; [ "$a" = "YES" ] || die "Aborted."

# --- deps --------------------------------------------------------------------
log "Installing sbctl / tpm2-tools / clevis ..."
apk add --no-cache sbctl tpm2-tools clevis clevis-luks 2>/dev/null || \
  warn "Some packages unavailable — steps needing them will be skipped."

# --- 1. Secure Boot: own keys, sign boot chain -------------------------------
if command -v sbctl >/dev/null 2>&1; then
  log "Creating + enrolling Secure Boot keys (sbctl) ..."
  sbctl create-keys || warn "sbctl create-keys failed"
  # enroll-keys needs the firmware in SETUP MODE (clear existing keys in BIOS).
  # -m also keeps Microsoft keys (safer for firmware that needs them).
  sbctl enroll-keys -m 2>/dev/null || \
    warn "enroll-keys failed — put the firmware in SETUP MODE (clear Secure Boot keys in BIOS), then re-run."
  # Sign the removable UEFI bootloader + the kernel (paths from our layout).
  for f in /boot/EFI/BOOT/BOOTX64.EFI /boot/grub/x86_64-efi/core.efi /boot/vmlinuz-lts; do
    [ -f "$f" ] && { sbctl sign -s "$f" || warn "sign $f failed"; }
  done
  sbctl verify || true
  log "Now ENABLE Secure Boot in BIOS. sbctl status:"; sbctl status || true
else
  warn "sbctl not available — cannot manage Secure Boot keys here."
fi

# --- 2. Measured boot + TPM auto-unlock of the encrypted root ----------------
# Find the LUKS root partition (if the system was installed with ENCRYPT=1).
luks_dev="$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1 || true)"
if [ -n "$luks_dev" ] && command -v clevis >/dev/null 2>&1; then
  log "Binding LUKS ($luks_dev) to the TPM (PCR 7 = Secure Boot state) ..."
  # PCR 7 covers Secure Boot policy; add 0/2/4 for firmware+bootloader if wanted.
  clevis luks bind -d "$luks_dev" tpm2 '{"pcr_ids":"7"}' || \
    warn "clevis bind failed (needs the LUKS passphrase + a working TPM)."
  # NOTE: Alpine's mkinitfs has no upstream clevis hook, so automatic unlock at
  # boot also needs a clevis-in-initramfs hook. Until that exists, this records
  # the TPM binding but the initramfs still prompts for the passphrase. See the
  # README roadmap. (Manual unlock: `clevis luks unlock -d <dev>`.)
else
  [ -z "$luks_dev" ] && log "No LUKS device found (system not installed with ENCRYPT=1) — skipping TPM unlock."
fi

# --- 3. Measured-boot attestation (optional) ---------------------------------
if command -v tpm2_pcrread >/dev/null 2>&1; then
  log "Current TPM PCRs (record these; changes = tampering):"
  tpm2_pcrread sha256:0,2,4,7 2>/dev/null || true
fi

ok "Secure-boot/TPM step complete. Verify Secure Boot is ON in BIOS and reboot."
;;
tpm-initramfs-hook)
# =============================================================================
# host/tpm-initramfs-hook.sh   (TPM auto-unlock of the LUKS root on Alpine)
# -----------------------------------------------------------------------------
# OPT-IN, EXPERIMENTAL. Makes the encrypted root unlock AUTOMATICALLY from the
# TPM when the measured boot chain is unmodified — no passphrase typing. If the
# TPM refuses (tampering / wrong PCRs) it falls back to the normal passphrase
# prompt, so worst case is "you type the passphrase", not a brick.
#
# Why this is needed: Alpine's mkinitfs ships no clevis hook, so even after
# `clevis luks bind` (done by host/secure-boot.sh) the initramfs never calls the
# TPM. This bundles clevis + tpm2 into the initramfs and patches the init to try
# `clevis luks unlock` before prompting.
#
# Prereq: run host/secure-boot.sh first (it binds the LUKS volume to the TPM).
# Test on a spare — a broken initramfs means you must boot recovery media.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root

INIT=/usr/share/mkinitfs/initramfs-init
[ -f "$INIT" ] || die "mkinitfs init ($INIT) not found — is mkinitfs installed?"

# The LUKS device + its cmdline mapper name (from our grub cmdline: cryptdm=cryptroot).
luks_dev="$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1 || true)"
[ -n "$luks_dev" ] || die "No LUKS device found — nothing to auto-unlock (install with ENCRYPT=1 first)."
cryptdm="$(grep -o 'cryptdm=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2 || true)"
: "${cryptdm:=cryptroot}"

warn "EXPERIMENTAL: patches the initramfs. If auto-unlock fails you fall back to"
warn "the passphrase prompt (not a brick). Have recovery media + the passphrase."
printf 'Type YES to proceed: '; read -r a; [ "$a" = "YES" ] || die "Aborted."

# --- deps --------------------------------------------------------------------
log "Installing clevis + tpm2 userspace ..."
apk add --no-cache clevis clevis-luks tpm2-tools jose cryptsetup 2>/dev/null || \
  die "Required packages unavailable (clevis/clevis-luks/tpm2-tools/jose)."

# --- 1. mkinitfs feature 'clevistpm': bundle the tools into the initramfs -----
# mkinitfs resolves shared-lib deps for listed binaries automatically. Include
# the clevis pipeline, TPM tools, jose, cryptsetup, plus /dev/tpm access helpers.
feat=/etc/mkinitfs/features.d/clevistpm.files
mkdir -p /etc/mkinitfs/features.d
{
  echo "/usr/bin/clevis*"
  echo "/usr/libexec/clevis*"
  echo "/usr/bin/jose"
  echo "/usr/bin/tpm2*"
  echo "/usr/bin/cryptsetup"
  echo "/usr/bin/mktemp"
  echo "/bin/grep"
  echo "/usr/lib/libtss2*"
} > "$feat"
log "Wrote mkinitfs feature: $feat"

# --- 2. Patch the init to try clevis before the passphrase prompt ------------
# We insert, right before the first 'cryptsetup luksOpen' the init runs, an
# attempt to unlock via the TPM. If it succeeds, the mapper already exists and
# the normal open becomes a no-op / is skipped.
if ! grep -q 'CLEVIS-TPM-AUTOUNLOCK' "$INIT"; then
  [ -f "$INIT.orig" ] || cp "$INIT" "$INIT.orig"
  # Find the crypt-open line; insert our block before it. Match common patterns.
  awk '
    /cryptsetup luksOpen|cryptsetup open|cryptsetup .*luksOpen/ && !done {
      print "# --- CLEVIS-TPM-AUTOUNLOCK (host/tpm-initramfs-hook.sh) ---"
      print "if command -v clevis >/dev/null 2>&1; then"
      print "  clevis luks unlock -d \"$cryptdev\" -n \"$cryptdm\" 2>/dev/null && echo \"TPM auto-unlock OK\" || true"
      print "fi"
      print "if [ -e \"/dev/mapper/$cryptdm\" ]; then : ; else"
      print "  # fall through to the normal passphrase open below"
      print "  :"
      print "fi"
      done=1
    }
    { print }
  ' "$INIT.orig" > "$INIT.new" && mv "$INIT.new" "$INIT"
  chmod +x "$INIT"
  warn "Patched $INIT (backup at $INIT.orig). Variable names (\$cryptdev/\$cryptdm)"
  warn "may differ across mkinitfs versions — VERIFY against $INIT.orig and adjust."
else
  log "init already patched."
fi

# --- 3. Enable the feature + rebuild the initramfs ---------------------------
conf=/etc/mkinitfs/mkinitfs.conf
touch "$conf"
if grep -q '^features=' "$conf"; then
  grep -q 'clevistpm' "$conf" || sed -i 's/^features="\(.*\)"/features="\1 clevistpm"/' "$conf"
else
  echo 'features="ata base ide scsi usb virtio ext4 cryptsetup keymap clevistpm"' >> "$conf"
fi
kver="$(ls /lib/modules | head -1)"
log "Rebuilding initramfs for $kver ..."
mkinitfs "$kver" || die "mkinitfs failed — restore $INIT.orig and retry."

ok "TPM initramfs hook installed. Reboot: an untampered boot should unlock the"
ok "root from the TPM with no passphrase; tampering falls back to the prompt."
warn "VERIFY on a spare first. If it hangs, boot recovery media and restore"
warn "$INIT.orig, then re-run mkinitfs."
;;
compliance-check)
# =============================================================================
# host/compliance-check.sh   (T-17 / SO-12 — post-install conformity gate)
# -----------------------------------------------------------------------------
# The provisioning sequence deliberately does NOT abort a machine mid-setup: a
# half-provisioned appliance is easier to finish than to rebuild. That choice is
# defensible, but it means a machine can reach the desktop with a step silently
# skipped — no isolation table, seeds never ejected, secrets never scrubbed —
# and nothing tells the operator. This is that missing control: it verifies, from
# the host and read-only, that the security-relevant provisioning steps actually
# took effect, publishes a verdict where anything can read it, and exits non-zero
# when the machine is NOT fit for use so a boot hook / CI / operator can gate on
# it (see --gate below).
#
#   host/compliance-check.sh            run the checks, print + publish a verdict
#   host/compliance-check.sh --gate     same, but ALSO drop a boot-blocking marker
#                                        on failure (and remove it on success)
#   host/compliance-check.sh -v         verbose (show every passing check too)
#
# Exit: 0 = COMPLIANT, 1 = NON-COMPLIANT (a required step did not take), 2 =
# UNKNOWN (could not evaluate — e.g. run before setup, or virsh/nft missing).
# Read-only: it inspects state, it never changes the machine (except the marker
# under --gate, which lives in tmpfs and only ever reflects the latest verdict).
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root
load_config

VERBOSE=0; GATE=0
for _a in "$@"; do
  case "$_a" in
    --gate) GATE=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "Unknown argument '$_a' (use --gate, -v)." ;;
  esac
done

# CONTRACT A (shared with isolation-watch): tmpfs status file, one TAB-separated
# line "STATE EPOCH DETAIL". Lives in /run so a stale verdict never survives a
# reboot — after a boot the honest answer is "re-checked", never a cached PASS.
STATUS_DIR="/run/appliance"
STATUS_FILE="$STATUS_DIR/compliance.status"
GATE_MARKER="$STATUS_DIR/NONCOMPLIANT"      # present == last verdict was FAIL

PASS=0; FAILN=0; WARN=0
_ok()   { PASS=$((PASS+1));  [ "$VERBOSE" = 1 ] && ok   "$1" || true; }
_fail() { FAILN=$((FAILN+1)); warn "NON-COMPLIANT: $1"; }
_warn() { WARN=$((WARN+1));  warn "advisory: $1"; }

# --- 1. Every ENABLED env has a defined, autostart domain --------------------
# NB: `for X in $(...)` runs its body in the CURRENT shell (unlike `... | while`),
# so the _ok/_fail counters below are mutated here, not lost in a subshell.
require_cmds virsh
_defined="$(virsh list --all --name 2>/dev/null || true)"
for env in $(for_each_enabled_env | awk '{print $1}'); do
  if printf '%s\n' "$_defined" | grep -qx "$env"; then
    if virsh dominfo "$env" 2>/dev/null | grep -qi '^Autostart:.*enable'; then
      _ok "domain '$env' defined + autostart"
    else
      _fail "domain '$env' is defined but autostart is OFF (won't come up on boot)"
    fi
  else
    _fail "enabled env '$env' has no libvirt domain (create.sh did not run for it)"
  fi
done

# --- 2. Inter-env isolation table is loaded ----------------------------------
if command -v nft >/dev/null 2>&1; then
  if nft list table inet appliance_isol >/dev/null 2>&1 \
     && nft list table inet appliance_isol 2>/dev/null | grep -q 'drop'; then
    _ok "isolation table inet appliance_isol present with drop rules"
  else
    _fail "isolation table inet appliance_isol missing or has no drop rules (isolate.sh did not run)"
  fi
else
  _warn "nft not available — cannot verify the isolation table"
fi

# --- 3. Provisioning seeds ejected (T-02): no plaintext-secret media attached -
_seed_left=0
for env in $(for_each_enabled_env | awk '{print $1}'); do
  if virsh domblklist "$env" 2>/dev/null | awk '{print $NF}' | grep -qE '\-(seed|unattend)\.iso$'; then
    _fail "env '$env' still has a provisioning ISO attached (seed not ejected — plaintext password exposed)"
    _seed_left=$((_seed_left+1))
  fi
done
[ "$_seed_left" = 0 ] && _ok "no provisioning seed/unattend ISO attached to any domain"

# --- 4. Operational secrets scrubbed from config.env (advisory) --------------
# scrub-secrets.sh is the documented LAST step and is optional, so a still-set
# password is a warning, not a hard fail — but a fielded machine should have run
# it. (config.env is 0600; we only test emptiness, never print the value.)
if grep -q '^GUEST_PASSWORD=""' "$CONFIG_ENV" 2>/dev/null; then
  _ok "GUEST_PASSWORD scrubbed from config.env"
else
  _warn "GUEST_PASSWORD still present in config.env — run scrub-secrets.sh once provisioning is confirmed"
fi

# --- 5. Kiosk libvirt access is confined (T-03) ------------------------------
if [ -f /etc/libvirt/libvirtd.conf ] \
   && grep -q '^auth_unix_rw *= *"none"' /etc/libvirt/libvirtd.conf 2>/dev/null; then
  _warn "libvirt auth_unix_rw=none — kiosk has unconfined (root-equivalent) libvirt access (T-03 not in effect on this host)"
else
  _ok "libvirt kiosk access is not the unconfined auth_unix_rw=none"
fi

# --- 6. Continuous isolation verdict is not FAIL -----------------------------
if [ -r "$STATUS_DIR/isolation.status" ]; then
  _istate="$(cut -f1 "$STATUS_DIR/isolation.status" 2>/dev/null || echo UNKNOWN)"
  case "$_istate" in
    OK)      _ok "continuous isolation watch reports OK" ;;
    FAIL)    _fail "continuous isolation watch reports FAIL (isolation is currently broken)" ;;
    *)       _warn "isolation watch verdict is '$_istate' (not yet verified this boot)" ;;
  esac
else
  _warn "no isolation-watch verdict yet (run isolate.sh / isolation-watch.sh --once)"
fi

# --- Verdict -----------------------------------------------------------------
mkdir -p "$STATUS_DIR" 2>/dev/null || true
if [ "$FAILN" -gt 0 ]; then
  STATE="NON-COMPLIANT"; RC=1
elif [ "$PASS" -eq 0 ]; then
  STATE="UNKNOWN"; RC=2
else
  STATE="COMPLIANT"; RC=0
fi
_detail="pass=$PASS fail=$FAILN warn=$WARN"
_tmp="$STATUS_FILE.$$"
if ( umask 022; printf '%s\t%s\t%s\n' "$STATE" "$(date -u +%s)" "$_detail" > "$_tmp" ) 2>/dev/null; then
  mv -f "$_tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$_tmp"
fi
audit_event compliance-check state="$STATE" "$_detail"

# --gate: publish a boot-blocking marker so a desktop-start hook can refuse to
# bring the kiosk up on a non-compliant machine. tmpfs, so it never persists a
# stale block across a reboot; removed the moment a run passes.
if [ "$GATE" = 1 ]; then
  if [ "$RC" = 1 ]; then
    ( umask 022; printf '%s\t%s\n' "$(date -u +%s)" "$_detail" > "$GATE_MARKER" ) 2>/dev/null || true
  else
    rm -f "$GATE_MARKER" 2>/dev/null || true
  fi
fi

printf '\nCompliance: %s  (%s)\n' "$STATE" "$_detail" >&2
case "$RC" in
  0) ok  "Appliance is COMPLIANT — all required provisioning steps took effect." ;;
  1) warn "Appliance is NON-COMPLIANT — $FAILN required step(s) did not take. Do not put this machine into service until fixed (see the lines above)." ;;
  2) warn "Compliance UNKNOWN — nothing to evaluate yet (run this after setup.sh steps 1-2)." ;;
esac
exit "$RC"
;;
update)
# =============================================================================
# host/update.sh — in-place update of the appliance CODE
# -----------------------------------------------------------------------------
# Without this, shipping a fix to a deployed machine means rebuilding the image,
# reflashing a stick, wiping the internal disk and losing every VM — which in
# practice means the machine in the field never gets the fix. This replaces the
# code tree at $APP_ROOT (/opt/appliance) and NOTHING else:
#
#   * config.env, the installer/first-boot markers, VM storage ($IMAGES_DIR) and
#     the libvirt domain definitions are the OPERATOR'S machine state. An update
#     replaces code, not state, so they are carried across untouched;
#   * the new tree is staged and validated (shape + shell syntax) BEFORE it is
#     swapped in: swapping in a broken tree would remove the only management
#     interface this appliance has;
#   * the swap is a rename, never a partial copy over the live tree, so there is
#     no window where half of one release is mixed with half of another;
#   * the previous tree is kept, so --rollback undoes a bad update.
#
# Signatures are mandatory: with no UPDATE_GPG_FPR pinned the update is REFUSED
# (fail closed), because "download and run as root" with no verification is a
# remote root shell for whoever can answer the URL.
#
#   host/update.sh              fetch, verify, validate, swap in, re-provision
#   host/update.sh --check      report what is available; change nothing
#   host/update.sh --rollback   restore the previous tree
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_root
load_config

usage() {
  cat <<'EOF'
Usage: host/update.sh [--check|--rollback]

  (no option)   fetch + verify + validate + swap in, then re-run the host scripts
  --check       report the available version and change nothing (also -n)
  --rollback    restore the most recent backup taken by a previous update

config.env keys:
  UPDATE_CHANNEL       tarball (default) | git
  UPDATE_URL           tarball URL; its detached signature is UPDATE_URL + ".sig"
  UPDATE_GIT_REMOTE    git remote (UPDATE_CHANNEL=git)
  UPDATE_GIT_REF       git tag/branch/commit to move to (default: main)
  UPDATE_GPG_FPR       pinned fingerprint of the release signing key (REQUIRED)
  UPDATE_GPG_KEYRING   optional keyring file holding that key
  UPDATE_INSECURE      1 = accept an unverified update (dangerous, off by default)
  UPDATE_KEEP_BACKUPS  how many previous trees to keep (default 3, minimum 1)
  UPDATE_BACKUP_DIR    where they are kept (default: <tree>.backups)
  UPDATE_REPROVISION   1 = re-run the host scripts after the swap (default 1)
  UPDATE_REQUIRE_VMS_OFF  1 = refuse to update while any VM is running
EOF
}

MODE="apply"
case "${1:-}" in
  ""|--apply)           MODE="apply" ;;
  --check|--dry-run|-n) MODE="check" ;;
  --rollback)           MODE="rollback" ;;
  -h|--help)            usage; exit 0 ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

LIVE="$APP_ROOT"
PARENT="$(dirname "$LIVE")"
# Default the backups next to the tree rather than in a fixed shared directory:
# it is on the same filesystem (so the swap stays a rename) and it can never mix
# up two appliance trees living under the same parent.
BACKUPS="${UPDATE_BACKUP_DIR:-$LIVE.backups}"
KEEP="${UPDATE_KEEP_BACKUPS:-3}"
case "$KEEP" in ''|*[!0-9]*) KEEP=3 ;; esac
[ "$KEEP" -ge 1 ] || KEEP=1          # a rollback needs at least the previous tree
CHANNEL="${UPDATE_CHANNEL:-tarball}"
REPROVISION="${UPDATE_REPROVISION:-1}"

# State that belongs to THIS machine and must survive a code swap.
#   .installed-system  — its absence makes the first-boot service believe it is
#                        the USB installer and re-wipe the internal disk. Losing
#                        this file on an update would destroy every VM.
#   .firstboot-done    — without it first boot re-runs provisioning at every boot.
#   .config-baked      — tells the installer the shipped config.env is deliberate.
#   config.env         — the operator's configuration AND all of the secrets.
PRESERVE=".installed-system .firstboot-done .config-baked config.env"

# --- audit (CONTRACT B) ------------------------------------------------------
# audit_event lives in lib/common.sh. An appliance still running an older lib
# must remain updatable — that is the whole point of this script — so a missing
# helper degrades to a no-op instead of aborting the update.
audit() {
  command -v audit_event >/dev/null 2>&1 || return 0
  audit_event "$@" >/dev/null 2>&1 || true
}
# CONTRACT B values carry no whitespace: fold anything that could.
sane() { printf '%s' "${1:-unknown}" | tr '[:space:]' '_'; }

file_sum() {
  [ -f "$1" ] || { printf 'absent'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else cksum "$1" | cut -d' ' -f1; fi
}

# tree_version DIR — the release identity of a tree, for --check and the audit
# log. A VERSION file is authoritative; a git checkout describes itself.
tree_version() {
  if [ -r "$1/VERSION" ]; then
    sane "$(head -1 "$1/VERSION")"
  elif [ -d "$1/.git" ] && command -v git >/dev/null 2>&1; then
    sane "$(git -C "$1" describe --always --dirty --tags 2>/dev/null || echo unknown)"
  else
    printf 'unknown'
  fi
}

# --- single-writer lock ------------------------------------------------------
# mkdir is the atomic primitive available everywhere (no flock on busybox).
LOCKDIR="/run/appliance/update.lock"
STAGE=""
cleanup() {
  [ -z "$STAGE" ] || rm -rf "$STAGE" 2>/dev/null || true
  rm -rf "$LOCKDIR" 2>/dev/null || true
  :
}
take_lock() {
  mkdir -p /run/appliance
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    _pid="$(cat "$LOCKDIR/pid" 2>/dev/null || echo '')"
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
      die "another update is already running (pid $_pid)."
    fi
    # A machine that lost power mid-update must not be locked out of updating
    # forever, so a lock whose owner is gone is stale and gets cleared.
    warn "clearing a stale update lock (pid ${_pid:-unknown} is gone)"
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || die "cannot create $LOCKDIR"
  fi
  trap cleanup EXIT INT TERM
  printf '%s\n' "$$" > "$LOCKDIR/pid"
}

# --- refuse while the machine is mid-operation -------------------------------
guard_busy() {
  # Cheap and decisive: an environment script running right now is writing the
  # very files this update is about to replace under it.
  _ps="$( { ps -eo args 2>/dev/null || ps ax 2>/dev/null || true; } | \
          grep -E 'environments/(create|isolate|vpn)\.sh|installer/install-to-disk\.sh' | \
          grep -v grep || true )"
  [ -z "$_ps" ] || die "an environment operation is in flight — wait for it to finish."

  command -v virsh >/dev/null 2>&1 || return 0
  _vms="$(LIBVIRT_DEFAULT_URI=qemu:///system virsh -q list --state-running --name 2>/dev/null \
          | sed '/^$/d' | tr '\n' ' ' | sed 's/ *$//')"
  [ -n "$_vms" ] || return 0
  if [ "${UPDATE_REQUIRE_VMS_OFF:-0}" = "1" ]; then
    die "VMs are running ($_vms) and UPDATE_REQUIRE_VMS_OFF=1 — shut them down first."
  fi
  # Not fatal: the update never touches VM disks or domain XML. But the kiosk
  # session is reconfigured afterwards, so the operator should know.
  warn "VMs are running: $_vms"
  warn "Their disks and domain definitions are NOT touched, but the desktop is reloaded."
}

# --- VM storage must not live inside the tree we are about to rename ---------
guard_images_dir() {
  _live_real="$(readlink -f "$LIVE" 2>/dev/null || printf '%s' "$LIVE")"
  _img="${IMAGES_DIR:-/var/lib/libvirt/images}"
  _img_real="$(readlink -f "$_img" 2>/dev/null || printf '%s' "$_img")"
  case "$_img_real/" in
    "$_live_real"/*)
      die "IMAGES_DIR ($_img) is inside $LIVE. An update RENAMES that tree, which
    would move every VM disk out from under libvirt. Move IMAGES_DIR to its own
    path (e.g. /var/lib/libvirt/images) and re-run." ;;
  esac
}

# --- signature verification --------------------------------------------------
norm_fpr() { printf '%s' "${1:-}" | tr -d ' :' | tr '[:lower:]' '[:upper:]'; }

# The pinned fingerprint may be the primary key while the signature came from a
# signing subkey (or the reverse), so match it against every field of VALIDSIG —
# gpg prints both the signing key and the primary key on that line.
validsig_has_fpr() {
  grep '^\[GNUPG:\] VALIDSIG ' "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"
}

# No pinned key: refuse, unless the operator has explicitly accepted the risk.
insecure_or_die() {
  if [ "${UPDATE_INSECURE:-0}" = "1" ]; then
    warn "###############################################################"
    warn "UPDATE_INSECURE=1 — installing UNVERIFIED code as root."
    warn "Whoever can answer that URL (or MITM it) now owns this appliance."
    warn "Pin UPDATE_GPG_FPR instead. This is not a supported configuration."
    warn "###############################################################"
    return 0
  fi
  die "UPDATE_GPG_FPR is empty — refusing an unverified update (fail closed).
    Pin the release signing key's fingerprint in config.env, or set
    UPDATE_INSECURE=1 if you truly accept running unsigned code as root."
}

# verify_detached FILE SIGFILE — die unless FILE is signed by the pinned key.
verify_detached() {
  _fpr="$(norm_fpr "${UPDATE_GPG_FPR:-}")"
  [ -n "$_fpr" ] || { insecure_or_die; return 0; }
  require_cmds gpg
  [ -s "$2" ] || die "no detached signature at $UPDATE_URL.sig — refusing."
  _st="$STAGE/gpg-status.txt"
  _rc=0
  if [ -n "${UPDATE_GPG_KEYRING:-}" ]; then
    gpg --batch --no-default-keyring --keyring "$UPDATE_GPG_KEYRING" \
        --status-fd 3 --verify "$2" "$1" 3>"$_st" >/dev/null 2>>"$_st" || _rc=$?
  else
    gpg --batch --status-fd 3 --verify "$2" "$1" 3>"$_st" >/dev/null 2>>"$_st" || _rc=$?
  fi
  if [ "$_rc" -ne 0 ]; then
    sed 's/^/    /' "$_st" >&2 || true
    audit update result=refused reason=bad-signature channel="$(sane "$CHANNEL")"
    die "signature verification FAILED — refusing the update."
  fi
  # gpg exits 0 for a good signature by ANY key it trusts; the pin is what makes
  # this an update channel rather than "anyone with a key can push code".
  if ! validsig_has_fpr "$_st" "$_fpr"; then
    sed 's/^/    /' "$_st" >&2 || true
    audit update result=refused reason=wrong-key channel="$(sane "$CHANNEL")"
    die "signed, but not by the pinned key $_fpr — refusing the update."
  fi
  ok "Signature verified against pinned key $_fpr"
}

# --- fetch -------------------------------------------------------------------
fetch_url() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
  else
    wget -q -O "$2" "$1"
  fi
}

# stage_tarball DEST — download, verify, unpack into DEST.
stage_tarball() {
  [ -n "${UPDATE_URL:-}" ] || die "UPDATE_CHANNEL=tarball but UPDATE_URL is empty."
  # Transport MUST be encrypted (T-15 / SO-10). The detached signature already
  # guarantees integrity + authenticity, but plaintext HTTP leaks which release a
  # machine runs (a fingerprinting/targeting aid) and lets an on-path attacker
  # strip the .sig fetch or feed a downgrade. Refuse anything but https.
  case "$UPDATE_URL" in
    https://*) : ;;
    *) audit update result=refused reason=insecure-transport
       die "UPDATE_URL must be https:// — the update transport must be encrypted (T-15). Got: $UPDATE_URL" ;;
  esac
  require_cmds tar
  _tar="$STAGE/update.tar"
  log "Downloading $UPDATE_URL ..."
  fetch_url "$UPDATE_URL" "$_tar" || { audit update result=refused reason=download; die "download failed: $UPDATE_URL"; }
  [ -s "$_tar" ] || { audit update result=refused reason=empty-download; die "downloaded an empty file from $UPDATE_URL"; }

  if [ -n "$(norm_fpr "${UPDATE_GPG_FPR:-}")" ]; then
    log "Downloading $UPDATE_URL.sig ..."
    fetch_url "$UPDATE_URL.sig" "$STAGE/update.sig" \
      || { audit update result=refused reason=no-signature; die "no signature at $UPDATE_URL.sig — refusing."; }
  fi
  verify_detached "$_tar" "$STAGE/update.sig"

  mkdir -p "$DEST_X"
  # -f without an explicit compression flag: both GNU and busybox tar sniff
  # gzip/xz/bzip2, so a release can change compression without breaking updates.
  tar -xf "$_tar" -C "$DEST_X" || die "the downloaded archive could not be unpacked."
}

# stage_git DEST — fetch the configured ref, verify its signature, check it out.
stage_git() {
  require_cmds git
  [ -n "${UPDATE_GIT_REMOTE:-}" ] || die "UPDATE_CHANNEL=git but UPDATE_GIT_REMOTE is empty."
  _ref="${UPDATE_GIT_REF:-main}"
  log "Fetching $_ref from $UPDATE_GIT_REMOTE ..."
  git init -q "$DEST_X"
  git -C "$DEST_X" remote add origin "$UPDATE_GIT_REMOTE"
  git -C "$DEST_X" fetch -q --depth 1 origin "$_ref" || die "git fetch of $_ref failed."
  # Fetch the tag OBJECT as well: a signed annotated tag is how releases are
  # normally signed, and a shallow ref fetch alone leaves nothing to verify.
  git -C "$DEST_X" fetch -q --depth 1 origin "refs/tags/$_ref:refs/tags/$_ref" 2>/dev/null || true
  git -C "$DEST_X" checkout -q --detach FETCH_HEAD || die "git checkout of $_ref failed."

  _fpr="$(norm_fpr "${UPDATE_GPG_FPR:-}")"
  if [ -z "$_fpr" ]; then insecure_or_die; return 0; fi
  require_cmds gpg
  _st="$STAGE/git-status.txt"; _rc=0
  if git -C "$DEST_X" rev-parse -q --verify "refs/tags/$_ref" >/dev/null 2>&1; then
    git -C "$DEST_X" verify-tag --raw "$_ref" > "$_st" 2>&1 || _rc=$?
  else
    git -C "$DEST_X" verify-commit --raw HEAD > "$_st" 2>&1 || _rc=$?
  fi
  if [ "$_rc" -ne 0 ] || ! validsig_has_fpr "$_st" "$_fpr"; then
    sed 's/^/    /' "$_st" >&2 || true
    audit update result=refused reason=bad-signature channel=git
    die "$_ref is not signed by the pinned key $_fpr — refusing the update."
  fi
  ok "Git signature verified against pinned key $_fpr"
}

# --- validation --------------------------------------------------------------
# resolve_tree DIR — the extracted content, allowing for the single wrapper
# directory that `git archive`/GitHub tarballs put around everything.
resolve_tree() {
  if [ -e "$1/setup.sh" ]; then printf '%s' "$1"; return 0; fi
  _n=0; _only=""
  for _e in "$1"/*; do
    [ -e "$_e" ] || continue
    _n=$((_n+1)); _only="$_e"
  done
  if [ "$_n" = 1 ] && [ -d "$_only" ]; then printf '%s' "$_only"; return 0; fi
  printf '%s' "$1"
}

# validate_tree DIR — everything that must hold BEFORE we swap this in. A tree
# that fails here is thrown away and the live tree is never touched.
validate_tree() {
  _d="$1"; _bad=0
  for _p in src/lib.sh src/host.sh src/environments.sh setup.sh; do
    [ -e "$_d/$_p" ] || { warn "staged tree has no $_p — this is not an appliance tree"; _bad=1; }
  done
  [ "$_bad" = 0 ] || return 1
  # Not fatal, but an update that drops the updater strands the machine.
  [ -e "$_d/src/host.sh" ] || warn "the new tree has no src/host.sh — it could not be updated again."

  # Syntax-check every script with the interpreter its shebang actually names:
  # the host scripts are bash and would fail a busybox-ash parse for reasons
  # that have nothing to do with them being broken.
  find "$_d" -type f -name '*.sh' -print > "$STAGE/scripts.lst"
  while IFS= read -r _f; do
    case "$(head -1 "$_f" 2>/dev/null)" in
      *bash*) _sh="bash" ;;
      *)      _sh="sh" ;;
    esac
    command -v "$_sh" >/dev/null 2>&1 || _sh="sh"
    if ! "$_sh" -n "$_f" 2>"$STAGE/syntax.err"; then
      warn "syntax error in ${_f#"$_d"/}:"
      sed 's/^/    /' "$STAGE/syntax.err" >&2 || true
      _bad=1
    fi
  done < "$STAGE/scripts.lst"
  [ "$_bad" = 0 ]
}

# carry_state DIR — move this machine's state into the tree about to go live.
carry_state() {
  for _p in $PRESERVE; do
    [ -e "$LIVE/$_p" ] || continue
    # A release tarball must never win over the live file — especially not
    # config.env, which would replace the operator's secrets with a build
    # machine's, or blank them entirely.
    rm -rf "${1:?}/$_p"
    cp -a "$LIVE/$_p" "$1/$_p"
  done
  if [ -e "$1/config.env" ]; then
    chmod 600 "$1/config.env"
  elif [ -e "$LIVE/config.env" ]; then
    die "internal error: config.env was not carried into the new tree — aborting."
  fi
  # A tarball can carry any ownership/mode; the tree runs as root, so the kiosk
  # user must not be able to write to any of it.
  chown -R root:root "$1" 2>/dev/null || true
  chmod -R go-w "$1" 2>/dev/null || true
  chmod +x "$1"/src/*/*.sh "$1/setup.sh" 2>/dev/null || true
}

prune_backups() {
  [ -d "$BACKUPS" ] || return 0
  _n="$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [ "$_n" -gt "$KEEP" ] || return 0
  # Names are UTC timestamps, so lexical order is chronological order.
  find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | sort | head -n "$((_n - KEEP))" \
    | while IFS= read -r _old; do rm -rf "$_old"; done
}

# swap_in NEWTREE — atomically make NEWTREE the live tree, keeping the old one.
# Prints the backup path on stdout.
swap_in() {
  mkdir -p "$BACKUPS"; chmod 700 "$BACKUPS"
  _bak="$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)"
  # Two updates inside the same second must not collide (the tests do exactly
  # that, and so does an operator re-running after a quick fix).
  if [ -e "$_bak" ]; then _bak="$_bak.$$"; fi
  mv "$LIVE" "$_bak" || die "could not move the current tree aside — nothing changed."
  if ! mv "$1" "$LIVE"; then
    # Never leave the appliance with no tree at all.
    mv "$_bak" "$LIVE" || die "CRITICAL: the tree is at $_bak and could not be restored to $LIVE."
    die "could not swap the new tree in — the previous tree was restored."
  fi
  printf '%s' "$_bak"
}

# --- post-swap re-provisioning ----------------------------------------------
# Same order and same resilience as the first-boot service in src/build.sh:
# each step runs independently so one failure cannot wedge the machine. Executed
# directly (not via `sh`) so each script's own shebang picks its interpreter.
reprovision() {
  if [ "$REPROVISION" = "0" ]; then
    warn "UPDATE_REPROVISION=0 — new code is in place but not applied yet."
    warn "Run host/detect-and-install.sh, configure.sh, harden.sh, switching.sh to apply it."
    return 0
  fi
  log "Re-running the host scripts so the new code takes effect ..."
  "$LIVE/src/host.sh" detect-and-install || warn "host/detect-and-install failed"
  "$LIVE/src/host.sh" configure          || warn "host/configure failed"
  "$LIVE/src/host.sh" harden             || warn "host/harden failed"
  "$LIVE/src/host.sh" switching          || warn "host/switching failed"
}

# verify_state_intact BACKUP — the update replaces code, not machine state.
# Checked rather than assumed: a bad release could ship its own config.env and
# silently hand the operator someone else's secrets.
verify_state_intact() {
  if [ "$(file_sum "$LIVE/config.env")" != "$CFG_SUM" ]; then
    warn "config.env differs after the swap — restoring the operator's copy."
    cp -a "$1/config.env" "$LIVE/config.env" && chmod 600 "$LIVE/config.env"
  fi
  for _p in .installed-system .firstboot-done .config-baked; do
    if [ -e "$1/$_p" ] && [ ! -e "$LIVE/$_p" ]; then
      warn "$_p was lost in the swap — restoring it."
      cp -a "$1/$_p" "$LIVE/$_p"
    fi
  done
}

# =============================================================================
# main
# =============================================================================
CFG_SUM="$(file_sum "$LIVE/config.env")"
CUR_VER="$(tree_version "$LIVE")"

if [ "$MODE" = "rollback" ]; then
  take_lock
  guard_busy
  [ -d "$BACKUPS" ] || die "no backups in $BACKUPS — nothing to roll back to."
  PREV="$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
  [ -n "$PREV" ] || die "no backups in $BACKUPS — nothing to roll back to."
  STAGE="$(mktemp -d "$PARENT/.appliance-update.XXXXXX")"
  # Validate the backup too: it may be the tree that a partial update left broken.
  validate_tree "$PREV" || die "the backup at $PREV does not validate — refusing to restore it."
  RESTORE="$STAGE/tree"
  mv "$PREV" "$RESTORE"
  carry_state "$RESTORE"
  PREV_VER="$(tree_version "$RESTORE")"
  log "Rolling back $CUR_VER -> $PREV_VER"
  BAK="$(swap_in "$RESTORE")"
  verify_state_intact "$BAK"
  prune_backups
  ok "Rolled back to $PREV_VER (previous tree kept at $BAK)"
  audit update result=rolled-back "from=$(sane "$CUR_VER")" "to=$(sane "$PREV_VER")"
  reprovision
  exit 0
fi

take_lock
guard_busy
guard_images_dir
STAGE="$(mktemp -d "$PARENT/.appliance-update.XXXXXX")"
DEST_X="$STAGE/x"

case "$CHANNEL" in
  tarball) stage_tarball ;;
  git)     stage_git ;;
  *)       die "unknown UPDATE_CHANNEL '$CHANNEL' (expected tarball or git)." ;;
esac

NEW="$(resolve_tree "$DEST_X")"
if ! validate_tree "$NEW"; then
  audit update result=refused reason=invalid-tree channel="$(sane "$CHANNEL")"
  die "the staged tree failed validation — the live tree was NOT touched."
fi
NEW_VER="$(tree_version "$NEW")"

if [ "$MODE" = "check" ]; then
  printf 'channel:   %s\n' "$CHANNEL"
  printf 'current:   %s\n' "$CUR_VER"
  printf 'available: %s\n' "$NEW_VER"
  if [ "$CUR_VER" = "$NEW_VER" ] && [ "$CUR_VER" != "unknown" ]; then
    ok "Already up to date (nothing was changed)."
  else
    ok "An update is available (nothing was changed — re-run without --check to apply)."
  fi
  audit update result=checked "from=$(sane "$CUR_VER")" "to=$(sane "$NEW_VER")" channel="$(sane "$CHANNEL")"
  exit 0
fi

carry_state "$NEW"
log "Applying $CUR_VER -> $NEW_VER"
BAK="$(swap_in "$NEW")"
verify_state_intact "$BAK"
prune_backups
ok "Updated to $NEW_VER (previous tree kept at $BAK — 'host/update.sh --rollback' undoes this)"
audit update result=applied "from=$(sane "$CUR_VER")" "to=$(sane "$NEW_VER")" channel="$(sane "$CHANNEL")"
reprovision
ok "Update complete."
;;
update-packages)
# =============================================================================
# host/update-packages.sh   (T-11 / SO-9 — maintien en condition de sécurité)
# -----------------------------------------------------------------------------
# host/update.sh ships new appliance CODE; this ships new PACKAGES — the security
# fixes for the base OS and the guests. Without it, a published vulnerability in
# the host or a guest is never closed and the risk grows mechanically (SO-9, one
# of the two Critical scenarios).
#
# It also emits a Software Bill of Materials (SBOM): the installed-package
# inventory of the host and every reachable guest, timestamped, so a new CVE can
# be matched against what this machine actually runs. The difficulty T-11 names
# is organisational (a named owner + a cadence, e.g. critical <=15d / important
# <=30d per the base standard) — this is the tool that cadence drives; wire it to
# a timer or run it on your review cycle.
#
#   host/update-packages.sh              upgrade host + reachable guests, write SBOM
#   host/update-packages.sh --sbom-only  inventory only; change nothing
#   host/update-packages.sh --host-only  upgrade the host only (skip guests)
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/lib.sh" ]; then . "$HERE/lib.sh"
elif [ -f "$HERE/lib.sh" ]; then . "$HERE/lib.sh"
else echo "[x] cannot find lib/common.sh"; exit 1; fi
require_root
load_config

MODE="full"
for _a in "$@"; do
  case "$_a" in
    --sbom-only) MODE="sbom" ;;
    --host-only) MODE="host" ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "Unknown argument '$_a' (use --sbom-only or --host-only)." ;;
  esac
done

SBOM_DIR="/var/lib/appliance-sbom"
mkdir -p "$SBOM_DIR" 2>/dev/null || true
SBOM="$SBOM_DIR/sbom-$(date -u '+%Y%m%dT%H%M%SZ').txt"
_sbom() { ( umask 077; printf '%s\n' "$1" >> "$SBOM" ) 2>/dev/null || true; }

# --- host package manager (Alpine apk, with apt/pacman/dnf fallbacks) --------
host_upgrade() {
  step "Host packages"
  if command -v apk >/dev/null 2>&1; then
    run apk update && run apk upgrade --available && ok "host: apk upgrade done." || warn "host: apk upgrade had errors."
  elif command -v apt-get >/dev/null 2>&1; then
    run apt-get update && run apt-get -y dist-upgrade && ok "host: apt upgrade done." || warn "host: apt upgrade had errors."
  elif command -v pacman >/dev/null 2>&1; then
    run pacman -Syu --noconfirm && ok "host: pacman upgrade done." || warn "host: pacman upgrade had errors."
  else
    warn "host: no known package manager (apk/apt/pacman) — skipped."
  fi
}
host_inventory() {
  if command -v apk >/dev/null 2>&1; then apk info -v 2>/dev/null | sort
  elif command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W -f '${Package}=${Version}\n' 2>/dev/null | sort
  elif command -v pacman >/dev/null 2>&1; then pacman -Q 2>/dev/null | sort
  fi
}

# --- guest helper: run one command in a domain via the qemu-guest-agent -------
# Bounded poll; returns the guest command's stdout (may be empty). Best-effort:
# a guest with no agent, or shut off, is skipped — never fatal.
guest_run() {
  _dom="$1"; _cmd="$2"
  _out="$(virsh -q qemu-agent-command "$_dom" \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$_cmd\"],\"capture-output\":true}}" 2>/dev/null)" || return 1
  _pid="$(printf '%s' "$_out" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')"
  [ -n "$_pid" ] || return 1
  _i=0
  while [ "$_i" -lt "${PKG_EXEC_TIMEOUT:-300}" ]; do
    _st="$(virsh -q qemu-agent-command "$_dom" \
      "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$_pid}}" 2>/dev/null)" || return 1
    case "$_st" in *'"exited":true'*|*'"exited": true'*)
      # out-data is base64; decode if present so the SBOM is readable.
      _b64="$(printf '%s' "$_st" | sed -n 's/.*"out-data":"\([^"]*\)".*/\1/p')"
      [ -n "$_b64" ] && printf '%s' "$_b64" | base64 -d 2>/dev/null || true
      return 0 ;;
    esac
    sleep 2; _i=$((_i+2))
  done
  return 1
}

# apt vs pacman inside the guest, chosen from its configured OS family.
guest_upgrade_cmd() { case "$1" in apt) printf 'DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade';; arch) printf 'pacman -Syu --noconfirm';; *) printf 'true';; esac; }
guest_inv_cmd()     { case "$1" in apt) printf 'dpkg-query -W -f=\${Package}=\${Version}\\\\n';; arch) printf 'pacman -Q';; *) printf 'true';; esac; }

# --- run ---------------------------------------------------------------------
_sbom "# Appliance SBOM  $(date -u '+%Y-%m-%dT%H:%M:%SZ')  host=$(hostname 2>/dev/null || echo '?')"
_sbom "## host"
host_inventory | while IFS= read -r _l; do _sbom "$_l"; done

if [ "$MODE" != "sbom" ]; then host_upgrade; fi

if [ "$MODE" = "host" ]; then
  ok "SBOM written: $SBOM (host only)."
  audit_event package-update scope=host mode="$MODE" sbom="$(basename "$SBOM")"
  exit 0
fi

# --- guests ------------------------------------------------------------------
if command -v virsh >/dev/null 2>&1; then
  for _env in $(for_each_enabled_env | awk '{print $1}'); do
    _fam="$(os_family "$(env_val "$_env" OS arch)")"
    case "$_fam" in windows) log "$_env: Windows guest — package MCS is via its own MDM/WSUS, skipped here."; continue;; esac
    step "Guest: $_env ($_fam)"
    if [ "$MODE" != "sbom" ]; then
      if guest_run "$_env" "$(guest_upgrade_cmd "$_fam")" >/dev/null 2>&1; then
        ok "$_env: package upgrade attempted (best-effort via guest agent)."
      else
        warn "$_env: could not upgrade (agent down / guest off / no network) — skipped."
      fi
    fi
    _sbom "## guest:$_env ($_fam)"
    _inv="$(guest_run "$_env" "$(guest_inv_cmd "$_fam")" 2>/dev/null || true)"
    if [ -n "$_inv" ]; then printf '%s\n' "$_inv" | while IFS= read -r _l; do _sbom "$_l"; done
    else _sbom "# (unreachable: agent down or guest off)"; fi
  done
fi

ok "Package maintenance complete. SBOM: $SBOM"
audit_event package-update scope=all mode="$MODE" sbom="$(basename "$SBOM")"
;;
secure-erase)
# =============================================================================
# host/secure-erase.sh   (T-08 / SO-4 — secure erasure + end-of-life)
# -----------------------------------------------------------------------------
# Decommissioning / reconditioning erasure. scrub-secrets.sh only blanks the
# config file; it leaves the VM disks (which hold the guests' data) and the
# operational secrets on the medium. This performs a real erase and produces a
# procès-verbal (PV) — the signed-off record a fleet owner needs before a machine
# leaves its custody.
#
# Method, cheapest-effective-first:
#   * LUKS-encrypted VM disk  -> CRYPTO-ERASE: `cryptsetup erase` destroys every
#     key slot, so the ciphertext is unrecoverable in milliseconds without
#     touching every block. This is why per-env disk encryption is worth it.
#   * plain qcow2 / raw       -> blkdiscard (SSD TRIM) if the file is on a block
#     device, else overwrite with shred (best effort on a copy-on-write fs).
#   * secrets at rest         -> shred config.env, the generated-secret notes,
#     the libvirt disk-encryption secret objects, and any leftover seed ISOs.
#
# DESTRUCTIVE + IRREVERSIBLE. It refuses to run without an explicit confirmation
# token, so it can never fire by accident, from a test, or from a stray hotkey.
#
#   host/secure-erase.sh                 explain + show what WOULD be erased
#   host/secure-erase.sh --vms           erase the VM disks + guest secrets
#   host/secure-erase.sh --all           also wipe host secrets (full decommission)
#   ... add  CONFIRM="ERASE"  to actually proceed, e.g.:
#       CONFIRM=ERASE host/secure-erase.sh --all
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
if [ -f "$HERE/lib.sh" ]; then . "$HERE/lib.sh"
elif [ -f "$HERE/lib.sh" ]; then . "$HERE/lib.sh"
else echo "[x] cannot find lib/common.sh"; exit 1; fi
require_root
load_config

SCOPE=""
for _a in "$@"; do
  case "$_a" in
    --vms) SCOPE="vms" ;;
    --all) SCOPE="all" ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) die "Unknown argument '$_a' (use --vms or --all)." ;;
  esac
done
[ -n "$SCOPE" ] || { sed -n '2,34p' "$0"; exit 0; }

IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
DRY=1
[ "${CONFIRM:-}" = "ERASE" ] && DRY=0

PV="/root/secure-erase-PV-$(date -u '+%Y%m%dT%H%M%SZ').txt"
PV_LINES=""
_pv() { PV_LINES="$PV_LINES
$1"; log "$1"; }

if [ "$DRY" = 1 ]; then
  warn "DRY RUN — nothing will be erased. Re-run with CONFIRM=ERASE to proceed."
fi

step "Secure erase (scope=$SCOPE, $([ "$DRY" = 1 ] && echo DRY-RUN || echo LIVE))"
_pv "secure-erase scope=$SCOPE host=$(hostname 2>/dev/null || echo '?') when=$(date -u '+%Y-%m-%dT%H:%M:%SZ') by=${SUDO_USER:-$(id -un 2>/dev/null || id -u)}"

# --- VM disks ----------------------------------------------------------------
erase_disk() {
  _d="$1"
  [ -e "$_d" ] || return 0
  # LUKS? crypto-erase the header. (`isLuks` works on files via loop-less probe.)
  if command -v cryptsetup >/dev/null 2>&1 && cryptsetup isLuks "$_d" 2>/dev/null; then
    if [ "$DRY" = 1 ]; then _pv "WOULD crypto-erase (LUKS) $_d"; else
      cryptsetup erase --batch-mode "$_d" 2>/dev/null && _pv "crypto-erased (LUKS keyslots) $_d" \
        || _pv "FAILED crypto-erase $_d"
      rm -f "$_d" 2>/dev/null && _pv "removed $_d" || true
    fi
  else
    if [ "$DRY" = 1 ]; then _pv "WOULD shred + remove $_d ($(_sz "$_d"))"; else
      shred -u "$_d" 2>/dev/null && _pv "shredded + removed $_d" \
        || { rm -f "$_d" 2>/dev/null && _pv "removed (shred unavailable) $_d"; }
    fi
  fi
}
_sz() { du -h "$1" 2>/dev/null | awk '{print $1}' || echo '?'; }

for _f in "$IMAGES_DIR"/*.qcow2 "$IMAGES_DIR"/*.raw "$IMAGES_DIR"/*-seed.iso "$IMAGES_DIR"/*-unattend.iso; do
  [ -e "$_f" ] || continue
  erase_disk "$_f"
done

# libvirt disk-encryption secret objects (defined non-ephemeral by create.sh and
# never removed): undefine them so the passphrases do not outlive the disks.
if command -v virsh >/dev/null 2>&1; then
  for _u in $(virsh secret-list 2>/dev/null | awk 'NR>2 && $1 ~ /-/ {print $1}'); do
    if [ "$DRY" = 1 ]; then _pv "WOULD undefine libvirt secret $_u"; else
      virsh secret-undefine "$_u" >/dev/null 2>&1 && _pv "undefined libvirt secret $_u" || true
    fi
  done
fi

# --- Host secrets (full decommission only) -----------------------------------
if [ "$SCOPE" = "all" ]; then
  for _s in "$CONFIG_ENV" /root/luks-key.txt /root/generated-secrets.txt \
            /etc/wpa_supplicant/wpa_supplicant.conf; do
    [ -e "$_s" ] || continue
    if [ "$DRY" = 1 ]; then _pv "WOULD shred $_s"; else
      shred -u "$_s" 2>/dev/null && _pv "shredded $_s" || { rm -f "$_s" 2>/dev/null && _pv "removed $_s"; }
    fi
  done
  _pv "NOTE: the host root filesystem itself is NOT wiped here — for full media"
  _pv "      sanitisation boot external media and cryptsetup-erase / blkdiscard the"
  _pv "      whole disk, or physically destroy it, per your end-of-life policy."
fi

# --- Procès-verbal -----------------------------------------------------------
if [ "$DRY" = 0 ]; then
  ( umask 077; printf '%s\n' "$PV_LINES" > "$PV" ) 2>/dev/null \
    && ok "Procès-verbal written: $PV" || warn "could not write PV to $PV"
  audit_event secure-erase scope="$SCOPE" pv="$(basename "$PV")"
  ok "Secure erase complete (scope=$SCOPE)."
else
  cat <<EOF

This was a DRY RUN. To actually erase (IRREVERSIBLE):
    CONFIRM=ERASE $0 --$SCOPE
A procès-verbal will be written to /root/secure-erase-PV-*.txt.
EOF
fi
;;
-h|--help|"") _host_usage; [ -n "$_cmd" ] ;;
*) _host_usage; die "unknown command: $_cmd" ;;
esac
