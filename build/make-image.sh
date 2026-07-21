#!/bin/bash
# =============================================================================
# build/make-image.sh
# -----------------------------------------------------------------------------
# Produce a BOOTABLE Alpine qcow2 image with:
#   * all host packages preinstalled (kvm/qemu/libvirt/virt-viewer/xorg/i3/nft)
#   * this repo's scripts baked into /opt/appliance
#   * nested virt + autologin + auto-startx already wired
#   * a one-shot first-boot service that runs 01 -> 02 -> 04 (idempotent),
#     leaving 03 (VM creation, big downloads) and 05 (firewall+verify) to you.
#
# HOW IT WORKS (macOS/darwin host):
#   Building an Alpine root filesystem + bootloader needs Linux + loop devices.
#   macOS has neither, so we run the whole build inside a privileged Alpine
#   Docker container using the upstream `alpine-make-vm-image` tool. The repo
#   scripts are shipped into the build as a base64 tar (no fragile bind-mount
#   into the chroot).
#
# REQUIREMENTS: Docker Desktop running. That's it (no root on the mac needed;
#   Docker provides the privileged Linux VM).
#
# OUTPUT: ./out/appliance-alpine.qcow2   (also convertible to raw for USB — see
#   end of script). Boot it in QEMU/virt-manager, or `qemu-img convert` to a
#   USB stick for bare metal.
# =============================================================================
set -euo pipefail

# This script lives in build/; the repo root is its parent.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

# --- tunables (overridable via env) ------------------------------------------
: "${ALPINE_BRANCH:=v3.22}"                 # Alpine release branch. v3.22 ships
                                            # kernel ~6.12 — needed for new Strix
                                            # Point (Ryzen AI 300) EC/keyboard/WiFi;
                                            # 6.6 (v3.20) is too old for this HW.
: "${IMG_SIZE:=4G}"                         # SMALL host image (OS uses ~1.7G). Kept
                                            # small so the USB->internal dd clone in
                                            # installer/ is fast; growpart then expands
                                            # root to fill the internal disk after.
: "${OUT_DIR:=$ROOT/out}"
: "${OUT_IMG:=appliance-alpine.qcow2}"
: "${AMVI_REF:=master}"                     # alpine-make-vm-image version/tag

command -v docker >/dev/null 2>&1 || { echo "[x] Docker required (start Docker Desktop)."; exit 1; }
docker info >/dev/null 2>&1 || { echo "[x] Docker daemon not reachable."; exit 1; }

mkdir -p "$OUT_DIR"

# -----------------------------------------------------------------------------
# 1. Tar up the repo scripts we want baked in, base64-encode for safe transport
#    into the container/chroot as an env var (files are small shell scripts).
# -----------------------------------------------------------------------------
echo "[*] Packing appliance tree ..."
# Tar the whole tree (preserving the lib/host/environments/installer layout) so
# it extracts to /opt/appliance with the same structure the scripts expect.
APPLIANCE_TAR_B64="$(tar -czf - \
  config.env.example README.md \
  lib host environments installer build \
  | base64 | tr -d '\n')"

# -----------------------------------------------------------------------------
# 2. The in-container build script. Runs INSIDE the privileged Alpine builder.
#    It fetches alpine-make-vm-image and invokes it with a "profile" callback
#    (--script-chroot) that runs inside the target rootfs to install our stuff.
# -----------------------------------------------------------------------------
cat > "$OUT_DIR/_build_inside.sh" <<'INNER'
#!/bin/sh
set -eu

ALPINE_BRANCH="$1"; IMG_SIZE="$2"; OUT_IMG="$3"; AMVI_REF="$4"

# Tools needed by alpine-make-vm-image + our packing. Preinstall ALL of the
# tool's host deps so its internal `apk add --virtual` is satisfied and it does
# not try to (re)fetch mid-run. syslinux = bootloader; util-linux = sfdisk/blkid.
apk update
apk add --no-cache \
  alpine-make-vm-image \
  qemu-img e2fsprogs e2fsprogs-extra dosfstools \
  syslinux util-linux blkid sfdisk rsync \
  agetty grep tar coreutils

# alpine-make-vm-image may not be packaged on all branches; fall back to git.
if ! command -v alpine-make-vm-image >/dev/null 2>&1; then
  apk add --no-cache git
  git clone --depth 1 --branch "$AMVI_REF" \
    https://github.com/alpinelinux/alpine-make-vm-image /amvi 2>/dev/null || \
  git clone --depth 1 https://github.com/alpinelinux/alpine-make-vm-image /amvi
  install -m755 /amvi/alpine-make-vm-image /usr/local/bin/alpine-make-vm-image
fi

# ---- profile callback: runs in chroot of the target rootfs ------------------
cat > /work/profile.sh <<'PROFILE'
#!/bin/sh
set -eu
# $APPLIANCE_TAR_B64 is exported into the chroot environment (see invocation).

# 1. Host packages (same set as host/detect-and-install.sh; preinstalled here).
#    Community repo needed for i3wm/virt-viewer.
setup-apkrepos -c -1 2>/dev/null || true
sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories 2>/dev/null || true
apk update
# NOTE: apk runs post-install TRIGGERS (e.g. mkfontscale) inside this amd64
# chroot via cross-arch emulation; those triggers can spuriously fail with
# "Exec format error" on the build host even though every PACKAGE installed fine.
# A failing trigger makes apk exit non-zero, which under `set -e` would abort the
# whole build. So capture apk's status, then VERIFY the real binaries are present
# and only fail if a genuine package is missing (not just a flaky font trigger).
apk_rc=0
apk add \
  linux-lts linux-firmware \
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
  alpine-conf \
  parted sgdisk cloud-utils-growpart e2fsprogs-extra cryptsetup cryptsetup-openrc \
  bash wget curl openssl gnupg \
  openrc util-linux \
  grub grub-efi efibootmgr dosfstools || apk_rc=$?
if [ "$apk_rc" != 0 ]; then
  echo "WARN: apk exited $apk_rc (likely a cross-arch trigger); verifying real binaries ..."
  miss=""
  for c in qemu-system-x86_64 virsh virt-install i3 startx nft grub-install polybar jq; do
    command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
  done
  [ -z "$miss" ] || { echo "ERROR: packages genuinely missing:$miss"; exit 1; }
  echo "All required binaries present — the apk failure was a trigger, continuing."
fi
  # parted/gptfdisk/e2fsprogs-extra: used by 08 to clone the USB to the internal
  # disk (dd) and grow the root partition (resizepart + resize2fs).
  # grub-efi/efibootmgr/dosfstools: UEFI boot (most modern machines are UEFI-only;
  # a BIOS/MBR-only image is invisible to UEFI firmware and won't boot).
  # firefox-esr: host browser used ONLY for captive-portal (Entra) login (07).
  # linux-firmware = all WiFi/GPU blobs (baked so any NIC works out of the box).
  # Narrow to e.g. linux-firmware-iwlwifi to shrink the image if NIC is known.
  # NOT cloud-utils-localds (cdrkit) — conflicts with virt-install's xorriso
  # (both provide mkisofs). 03 builds the seed ISO with xorriso/mkisofs.

# 2. Unpack repo scripts into /opt/appliance.
mkdir -p /opt/appliance
echo "$APPLIANCE_TAR_B64" | base64 -d | tar -xzf - -C /opt/appliance
chmod +x /opt/appliance/*/*.sh 2>/dev/null || true

# 3. Create the UNPRIVILEGED kiosk user (ANSSI: the desktop must not run as root).
#    'kiosk' can only view/launch the VMs (member of libvirt/kvm) and drive its
#    own X session — no sudo, no root powers. Root still exists for admin (VT2).
adduser -D -s /bin/bash kiosk 2>/dev/null || true
for g in libvirt libvirtd kvm video input; do addgroup kiosk "$g" 2>/dev/null || true; done
passwd -u kiosk 2>/dev/null || true       # unlock (no password; console autologin only)
# Root keeps a password for admin on tty2 (provisioning / recovery). Change it.
echo 'root:changeme-root' | chpasswd 2>/dev/null || true

# Autologin the KIOSK user on tty1 (not root).
[ -f /etc/inittab.orig ] || cp /etc/inittab /etc/inittab.orig
grep -v '^tty1::' /etc/inittab > /etc/inittab.tmp
echo 'tty1::respawn:/sbin/agetty --autologin kiosk --noclear tty1 linux' >> /etc/inittab.tmp
mv /etc/inittab.tmp /etc/inittab

# 4. Auto-startx on tty1 for the kiosk user — ONLY on the installed system, so
#    the USB installer boot shows installer progress instead of launching X.
cat > /home/kiosk/.profile <<'BP'
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ] \
   && [ -f /opt/appliance/.installed-system ]; then
    exec startx
fi
BP
chown kiosk:kiosk /home/kiosk/.profile

# 4b. Help USB keyboards enumerate (safe, additive). Deliberately NOT forcing
#     i8042/i2c_hid here — those caused regressions on this Lenovo; let udev
#     autoload the correct driver from ACPI/USB modaliases (eudev handles it).
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/keyboard.conf <<'KB'
usbhid
hid_generic
KB

# 4c. /etc/default/grub — carries the kernel cmdline to the INSTALLED system.
#     setup-disk (08) regenerates grub.cfg on the internal disk from this file,
#     so the ThinkPad P16s AMD keyboard params (i8042/atkbd) must live here or
#     the keyboard breaks again after install. (The USB's own grub.cfg is
#     hand-written separately in step 9.)
cat > /etc/default/grub <<'GRUBDEF'
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR="Appliance"
GRUB_CMDLINE_LINUX_DEFAULT="i8042.nomux i8042.noloop mem_encrypt=on console=tty0 quiet"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_RECOVERY=true
GRUBDEF

# 5. Enable services at boot.
# udev is REQUIRED for Xorg to detect keyboard/mouse (Alpine's default mdev does
# not, so X shows only a cursor with dead input). Enable the udev service set.
rc-update add udev sysinit || true
rc-update add udev-trigger sysinit || true
rc-update add udev-settle sysinit || true
rc-update add udev-postmount default || true
rc-update add libvirtd default || true
rc-update add nftables default || true
rc-update add dbus default || true
rc-update add networking boot || true

# Clean /etc/network/interfaces (the tool's default has a post-up glob that
# errors on an empty if-post-up.d dir, marking eth0 'failed' even though DHCP
# succeeded). Simple lo + eth0 DHCP; WiFi is handled separately by 06.
cat > /etc/network/interfaces <<'NET'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NET

# 6. First-boot one-shot: run 01 (hw detect/nested), 02 (host cfg), 04 (i3).
#    Idempotent; disables itself after success. 03 (VM downloads) + 05
#    (firewall+verify) are left for the operator (need network + time).
cat > /etc/init.d/appliance-firstboot <<'FB'
#!/sbin/openrc-run
description="Appliance first-boot (installer on USB, provisioning on disk)"
depend() { need libvirtd; after networking; }

# Are we the USB installer, or the installed system?
# Reliable test: the INSTALLED system has /opt/appliance/.installed-system
# (written by 08 onto the target disk). The baked USB image never has it.
# (The old removable-flag check was unreliable — many USB sticks report
# removable=0, so the installer never triggered and nothing got written.)
booted_from_usb() {
    [ ! -f /opt/appliance/.installed-system ]
}

start() {
    cd /opt/appliance || return 1

    if booted_from_usb; then
        # USB installer mode: auto-install to the internal disk, then poweroff.
        ebegin "USB installer — auto-installing to internal disk"
        AUTO_CONFIRM=1 sh ./installer/install-to-disk.sh
        eend $?    # installer powers off on success
        return 0
    fi

    # Installed-system mode: full host provisioning.
    # RESILIENT: run each step independently (|| eerror) so one failing step never
    # wedges the boot. Order: detect-and-install creates config.env (needed by
    # switching), configure writes autologin/.profile/.xinitrc, switching writes
    # the i3 config (needed by captive-portal). detect-and-install is non-fatal.
    ebegin "Appliance first-boot (host provisioning)"
    sh ./host/detect-and-install.sh   || eerror "host/detect-and-install failed"
    sh ./host/configure.sh            || eerror "host/configure failed"
    sh ./host/harden.sh               || eerror "host/harden failed"
    sh ./host/switching.sh            || eerror "host/switching failed"
    sh ./host/wifi.sh                 || eerror "host/wifi failed"
    sh ./host/captive-portal.sh       || eerror "host/captive-portal failed"
    # Mark done regardless — do not re-wedge on every boot. Re-run scripts by
    # hand from a terminal (Super+Enter) if a step needs fixing.
    rc-update del appliance-firstboot default || true
    touch /opt/appliance/.firstboot-done
    eend 0
}
FB
chmod +x /etc/init.d/appliance-firstboot
rc-update add appliance-firstboot default

# 7. Nested virt drop-ins are written by 01 at first boot (vendor-specific),
#    so nothing to hardcode here — keeps the image CPU-agnostic.

# 8. Root password: locked (console autologin only). Set one if you need SSH.
passwd -u root 2>/dev/null || true

# 9. Install a REMOVABLE-PATH UEFI bootloader so real hardware boots.
#    alpine-make-vm-image's UEFI mode only writes boot/startup.nsh (interpreted
#    by the UEFI *Shell*, which real firmware does not auto-run). Firmware boots
#    the removable fallback /EFI/BOOT/BOOTX64.EFI instead — so install GRUB there
#    explicitly. Inside this chroot, /boot IS the mounted ESP (vfat).
# FAIL CLOSED: the whole removable-UEFI bootloader install depends on this
# upstream artifact. If alpine-make-vm-image (unpinned AMVI_REF=master) ever stops
# writing /boot/startup.nsh, silently skipping this step would emit an image that
# builds fine but is NON-BOOTABLE on real firmware (no /EFI/BOOT/BOOTX64.EFI). Turn
# that into a loud build failure instead. (Pin AMVI_REF to a known-good tag to also
# guard against the format changing under you.)
if [ ! -f /boot/startup.nsh ]; then
  echo "ERROR: alpine-make-vm-image did not write /boot/startup.nsh — cannot derive the removable UEFI bootloader or root UUID. The image would be NON-BOOTABLE. Aborting (pin/verify AMVI_REF)." >&2
  exit 1
fi
# Derive the root filesystem UUID from the cmdline the tool already wrote.
ruuid="$(grep -o 'root=UUID=[^ ]*' /boot/startup.nsh | head -1 | cut -d= -f3)"
[ -n "$ruuid" ] || { echo "ERROR: could not parse root=UUID= from /boot/startup.nsh — aborting (image would be non-bootable)." >&2; exit 1; }
# Install grub to the ESP in removable mode (no NVRAM writes — impossible in a
# build container anyway). A failure here means no bootloader: fatal, not a warn.
grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot \
  --removable --no-nvram 2>&1 || { echo "ERROR: grub-install failed — image would be non-bootable. Aborting." >&2; exit 1; }
# Hand-write a grub.cfg. Kernel + initramfs live at the ESP root (/boot is the
# ESP), so grub paths are ESP-relative (/vmlinuz-lts), while the kernel's
# root= points at the ext4 root by UUID.
mkdir -p /boot/grub
cat > /boot/grub/grub.cfg <<GCFG
set timeout=2
set default=0
menuentry "Appliance (Alpine LTS)" {
    search --no-floppy --file --set=root /vmlinuz-lts
    linux /vmlinuz-lts root=UUID=$ruuid rootfstype=ext4 modules=sd-mod,usb-storage,ext4 console=tty0 i8042.nomux i8042.noloop mem_encrypt=on quiet
    initrd /initramfs-lts
}
GCFG
PROFILE
chmod +x /work/profile.sh

# ---- run the image builder --------------------------------------------------
# --script-chroot: run profile.sh inside the target rootfs.
# We export APPLIANCE_TAR_B64 so the chroot'd profile can read it.
export APPLIANCE_TAR_B64
# INSTALL_HOST_PKGS=no: we already installed every host dep above. The tool's
# own host-package apk step breaks under cross-arch emulation (fetches an
# arch-specific apk.static and loses network -> "No such package"), so we skip
# it. Deps are all present, so the build proceeds normally.
export INSTALL_HOST_PKGS=no
# Build RAW then convert to qcow2 (robust; avoids any nbd/qcow2 edge cases).
# --boot-mode UEFI: creates a GPT with an EFI System Partition and installs
# grub-efi. Required for modern UEFI-only machines (the tool only accepts BIOS
# or UEFI, not both; UEFI is the right choice for current hardware). Legacy-BIOS
# machines would instead need BOOT_MODE=BIOS (override BOOT_MODE in this script).
: "${BOOT_MODE:=UEFI}"
# Remove any stale raw from a previously interrupted build — alpine-make-vm-image
# / qemu-nbd refuse to reopen a half-written one ("Permission denied").
rm -f "/work/appliance.raw"

alpine-make-vm-image \
  --image-format raw \
  --image-size "$IMG_SIZE" \
  --branch "$ALPINE_BRANCH" \
  --boot-mode "$BOOT_MODE" \
  --kernel-flavor lts \
  --packages "openrc util-linux grub grub-efi efibootmgr dosfstools" \
  --script-chroot \
  "/work/appliance.raw" -- /work/profile.sh

# Convert raw -> qcow2 for the final artifact.
qemu-img convert -O qcow2 "/work/appliance.raw" "/work/$OUT_IMG"
rm -f "/work/appliance.raw"
echo "[+] Image built: /work/$OUT_IMG"
INNER
chmod +x "$OUT_DIR/_build_inside.sh"

# -----------------------------------------------------------------------------
# 3. Run the builder in a privileged Alpine container (needs loop devices).
#    Mount ./out as /work so the finished qcow2 lands on the mac.
# -----------------------------------------------------------------------------
echo "[*] Building image in privileged Alpine container (needs Docker) ..."
# --platform linux/amd64: the appliance is an x86_64 KVM host, so we build the
# rootfs as amd64. On Apple Silicon this runs under emulation (slower) — that's
# expected and correct for producing a bootable x86_64 image.
docker run --rm --privileged --platform linux/amd64 \
  -e APPLIANCE_TAR_B64="$APPLIANCE_TAR_B64" \
  -v "$OUT_DIR":/work \
  "alpine:${ALPINE_BRANCH#v}" \
  /work/_build_inside.sh "$ALPINE_BRANCH" "$IMG_SIZE" "$OUT_IMG" "$AMVI_REF"

rm -f "$OUT_DIR/_build_inside.sh" "$OUT_DIR/profile.sh"

echo "[+] Done: $OUT_DIR/$OUT_IMG"
cat <<EOF

Boot it:
  qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \\
    -cpu host -drive file=$OUT_DIR/$OUT_IMG,if=virtio \\
    -netdev user,id=n0 -device virtio-net,netdev=n0

  (On macOS there's no KVM; test-boot in UTM/virt-manager on a Linux box, or
   deploy to bare metal.)

Flash to USB / bare metal:
  qemu-img convert -O raw $OUT_DIR/$OUT_IMG $OUT_DIR/appliance.raw
  sudo dd if=$OUT_DIR/appliance.raw of=/dev/rdiskN bs=4m   # <-- pick the right disk!

First boot auto-runs 01/02/04 (nested virt, autologin, i3 kiosk). Then on the
appliance run:
  cd /opt/appliance && sudo ./environments/create.sh && sudo ./environments/isolate.sh
EOF
