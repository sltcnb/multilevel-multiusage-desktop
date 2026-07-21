#!/bin/bash
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
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
require_cmds dd lsblk findmnt growpart resize2fs

# -----------------------------------------------------------------------------
# 1. Identify the disk we are BOOTED FROM (the USB) so we never target it.
# -----------------------------------------------------------------------------
root_src="$(findmnt -no SOURCE / || true)"          # e.g. /dev/sdb2 or /dev/sda2
# Strip partition suffix to get the parent disk (sdb2->sdb, nvme0n1p2->nvme0n1).
usb_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)"
[ -n "$usb_disk" ] || usb_disk="$(echo "$root_src" | sed -E 's|/dev/||; s|p?[0-9]+$||')"
log "Booted from (USB, will NOT touch): /dev/$usb_disk"

# -----------------------------------------------------------------------------
# 2. List candidate internal disks (whole disks, type 'disk', not the USB, not
#    removable). Pick the largest by default; show all for confirmation.
# -----------------------------------------------------------------------------
log "Block devices:"
lsblk -dno NAME,SIZE,TYPE,MODEL,RM | sed 's/^/    /'

# Candidates: type=disk, name != usb_disk, RM(removable)=0.
target=""
best_bytes=0
while read -r name _ type rm; do
  [ "$type" = "disk" ] || continue
  [ "$name" = "$usb_disk" ] && continue
  [ "$rm" = "0" ] || continue            # skip removable (other USBs)
  bytes="$(lsblk -dnbo SIZE "/dev/$name" | head -1)"
  if [ "$bytes" -gt "$best_bytes" ]; then best_bytes="$bytes"; target="$name"; fi
done <<EOF
$(lsblk -dno NAME,SIZE,TYPE,RM)
EOF

# Allow override: TARGET_DISK=nvme0n1 ./installer/install-to-disk.sh
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
src_rm="$(lsblk -dno RM "/dev/$usb_disk" | head -1)"
[ "$usb_disk" != "$target" ] || die "SOURCE == DEST ($usb_disk); aborting (would clone a disk onto itself)."
# The boot/source disk should be the removable USB. If it is NOT removable AND is
# larger than the target, we're almost certainly about to clone internal->USB by
# mistake — refuse. (Override with FORCE_DIRECTION=1 if you really mean it.)
if [ "${FORCE_DIRECTION:-0}" != "1" ] && [ "$src_rm" != "1" ] && [ "${src_bytes:-0}" -gt "${dst_bytes:-0}" ]; then
  die "Refusing: source /dev/$usb_disk (non-removable, larger) -> /dev/$target looks like internal->USB. Set FORCE_DIRECTION=1 to override."
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
  # If no passphrase was provided, GENERATE a strong one, save it to a
  # root-only keyfile, and print it. The operator MUST record it — it is the
  # only way to unlock the disk (until TPM auto-unlock is set up via
  # host/secure-boot.sh). openssl gives 32 bytes base64.
  if [ -z "${LUKS_PASS:-}" ] || [ "${LUKS_PASS:-}" = "generate" ]; then
    LUKS_PASS="$(openssl rand -base64 32 2>/dev/null || head -c24 /dev/urandom | base64)"
    keyout="/root/luks-key.txt"
    umask 077; printf '%s\n' "$LUKS_PASS" > "$keyout"
    warn "No LUKS_PASS set — GENERATED a random LUKS passphrase."
    warn "Saved to $keyout on the NEW system. RECORD IT NOW (shown once):"
    printf '\n    LUKS passphrase: %s\n\n' "$LUKS_PASS" >&2
  fi
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
  mount -o ro "/dev/${usb_disk}${usb_p}2" /mnt/src
  mount /dev/mapper/cryptroot /mnt/dst
  cp -a /mnt/src/. /mnt/dst/
  # Save the generated key inside the encrypted volume (safe: only readable once
  # the disk is already unlocked) so it is recoverable after the USB is gone.
  [ -f /root/luks-key.txt ] && { mkdir -p /mnt/dst/root; cp /root/luks-key.txt /mnt/dst/root/luks-key.txt; chmod 600 /mnt/dst/root/luks-key.txt; }
  umount /mnt/src
  log "Copying ESP (kernel/initramfs/grub) ..."
  mount "$esp" /mnt/dst/boot 2>/dev/null || { mkdir -p /mnt/dst/boot; mount "$esp" /mnt/dst/boot; }
  mount -o ro "/dev/${usb_disk}${usb_p}1" /mnt/src
  cp -a /mnt/src/. /mnt/dst/boot/
  umount /mnt/src
  luuid="$(blkid -s UUID -o value "$luks")"
  espuuid="$(blkid -s UUID -o value "$esp")"
  # initramfs must include cryptsetup so it can unlock root at boot.
  echo 'features="ata base ide scsi usb virtio ext4 cryptsetup keymap"' > /mnt/dst/etc/mkinitfs/mkinitfs.conf
  cat > /mnt/dst/etc/fstab <<F
/dev/mapper/cryptroot / ext4 rw,relatime 0 1
UUID=$espuuid /boot vfat rw,relatime 0 2
F
  cat > /mnt/dst/etc/default/grub <<G
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR="Appliance"
GRUB_CMDLINE_LINUX_DEFAULT="cryptroot=UUID=$luuid cryptdm=cryptroot i8042.nomux i8042.noloop console=tty0 quiet"
GRUB_CMDLINE_LINUX="root=/dev/mapper/cryptroot"
GRUB_ENABLE_CRYPTODISK=n
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
  1. Poweroff:            sudo poweroff
  2. Remove the USB stick.
  3. Power on — the machine boots the appliance from its internal disk.
  4. First boot auto-configures (01/02/06/04/07) with the FULL disk available,
     so the disk auto-split works. Then create the VMs:
        cd /opt/appliance && sudo ./environments/create.sh && sudo ./environments/isolate.sh
EOF
fi
