#!/bin/bash
# =============================================================================
# host/detect-and-install.sh
# -----------------------------------------------------------------------------
# Detect hardware, seed config.env, and produce a minimal Alpine KVM host that
# contains: kernel + KVM modules, qemu-kvm, libvirt, virt-viewer, minimal Xorg,
# and i3. Enables nested virtualization.
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
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

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
  # Intel nested virt param.
  NESTED_PARAM="options kvm_intel nested=1"
elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  CPU_VENDOR="amd"
  KVM_MODULE="kvm_amd"
  NESTED_PARAM="options kvm_amd nested=1"
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
    nftables wireguard-tools \
    xorg-server xf86-video-modesetting xf86-input-libinput setxkbmap \
    xkeyboard-config xkbcomp \
    eudev udev-init-scripts keyd keyd-openrc usbguard usbguard-openrc usbutils \
    xinit i3wm xterm ttf-dejavu \
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
    nftables wireguard-tools \
    xserver-xorg xinit i3 fonts-dejavu \
    cloud-image-utils genisoimage wget curl openssl
fi

# -----------------------------------------------------------------------------
# 7. Enable nested virtualization + load correct module.
#    Written as a modprobe.d drop-in so it survives reboots.
# -----------------------------------------------------------------------------
log "Enabling nested virt for $KVM_MODULE ..."
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

# Load now (reload to pick up nested=1 if already loaded without it).
modprobe -r "$KVM_MODULE" 2>/dev/null || true
modprobe "$KVM_MODULE"
# Verify nested actually turned on (both vendors report Y/1 when enabled).
nested_state="$(cat "/sys/module/${KVM_MODULE}/parameters/nested" 2>/dev/null || echo '?')"
case "$nested_state" in
  Y|1) ok "Nested virt ENABLED (nested=$nested_state).";;
  *)   warn "Nested virt not confirmed (nested=$nested_state). May need reboot.";;
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
    cd /opt/appliance && ./setup.sh        # numbered menu: Wi-Fi -> create -> isolate
EOF
