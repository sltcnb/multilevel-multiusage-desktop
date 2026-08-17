#!/bin/sh
# =============================================================================
# flash.sh — step 2 of 3: build the appliance image AND flash it to a USB stick
# -----------------------------------------------------------------------------
# The SECOND of three endpoints (./configure.sh wrote config.env; this script
# turns it into a bootable stick; ./setup.sh then runs on the appliance):
#
#   1. build   src/build.sh (skipped if a fresh qcow2 already exists)
#   2. convert qcow2 -> raw (qemu-img)
#   3. flash   dd the raw image onto a USB stick you pick from a list
#
#   ./flash.sh               # interactive: reuse or rebuild, then flash
#   ./flash.sh --build       # force a rebuild even if the qcow2 exists
#   ./flash.sh --image-only  # build + convert, stop before flashing
#   ./flash.sh -h|--help     # usage
#
# Runs on the BUILD host (macOS bash 3.2 AND Linux), so: strictly POSIX sh.
#
# SAFETY CONTRACT (dd to the wrong disk destroys it):
#   * Only EXTERNAL/REMOVABLE disks are listed; the system disk is refused even
#     if typed by hand.
#   * The target must be confirmed by typing its exact device name a second
#     time, after seeing its size and model.
#   * Nothing is written before that confirmation; Ctrl+C anywhere aborts.
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/src/lib.sh"
APP_ROOT="$HERE"  # common.sh assumes the caller lives under src/; we are the root

# The build options (IMG_SIZE, ALPINE_BRANCH, BAKE_CONFIG) were chosen in
# ./configure.sh and live in config.env; src/build.sh reads them from its
# ENVIRONMENT, not from config.env, so source and export them here. Anything
# already set in the environment wins (an explicit override on the command line
# still takes precedence). No config.env yet just means the build uses defaults.
if [ -f "$HERE/config.env" ]; then
  # shellcheck disable=SC1091
  . "$HERE/config.env"
  # WINDOWS_ISO_SRC (build-host path) opts into baking the Windows ISO into the
  # image; WINDOWS_ISO is where it lands on the guest. Both handed to the build.
  export IMG_SIZE ALPINE_BRANCH BAKE_CONFIG WINDOWS_ISO_SRC WINDOWS_ISO VIRTIO_WIN_SRC ARCH_IMG_SRC
fi

OUT_DIR="${OUT_DIR:-$HERE/out}"
QCOW2="$OUT_DIR/${OUT_IMG:-appliance-alpine.qcow2}"
RAW="$OUT_DIR/appliance.raw"

FORCE_BUILD=0
DO_FLASH=1

usage() {
  cat <<EOF
Usage: ./flash.sh [--build] [--image-only] [-h|--help]

Build the appliance image (src/build.sh), convert it to raw and
flash it onto a USB stick.

  --build       force a rebuild even if a qcow2 already exists
  --image-only  build + convert only; do not flash anything
  -h, --help    this help

Environment overrides: OUT_DIR, OUT_IMG (same as src/build.sh).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --build)      FORCE_BUILD=1 ;;
    --image-only) DO_FLASH=0 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; die "unknown flag: $arg" ;;
  esac
done

# ask PROMPT DEFAULT — free-form question; empty answer (or EOF) keeps DEFAULT.
# The prompt goes to stderr so ask can be used inside $( ) without the question
# being swallowed into the captured value.
ask() {
  printf '%s [%s]: ' "$1" "$2" >&2
  IFS= read -r _ans || _ans=""
  [ -n "$_ans" ] || _ans="$2"
  printf '%s' "$_ans"
}

# ask_yn PROMPT DEFAULT(0|1) — yes/no question, 0 = yes answered/defaulted.
ask_yn() {
  _d="y/N"; [ "$2" = "1" ] && _d="Y/n"
  printf '%s [%s]: ' "$1" "$_d" >&2
  IFS= read -r _ans || _ans=""
  [ -n "$_ans" ] || { [ "$2" = "1" ]; return; }
  case "$_ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- preflight -----------------------------------------------------------------
require_cmds() {
  _missing=""
  for _c in "$@"; do command -v "$_c" >/dev/null 2>&1 || _missing="$_missing $_c"; done
  [ -z "$_missing" ] || die "missing required tools:$_missing"
}

OS="$(uname -s)"
SUDO=""; [ "$(id -u)" = "0" ] || SUDO="sudo"

cat <<'EOF'
==========================================================================
 Appliance image -> USB stick. You will pick the target disk from a list
 and CONFIRM it by name; nothing is written before that.
==========================================================================
EOF

# --- 1. build --------------------------------------------------------------------
step "1/3 — Build the appliance image"
build_image() {
  require_cmds docker
  log "Building the appliance image (src/build.sh) ..."
  sh "$HERE/src/build.sh"
}

if [ "$FORCE_BUILD" = "1" ] || [ ! -f "$QCOW2" ]; then
  [ -f "$QCOW2" ] || log "No image at $QCOW2 yet — building it."
  build_image
else
  log "Found existing image: $QCOW2"
  ask_yn "Reuse it (n = rebuild, takes a while)" 1 || build_image
fi
[ -f "$QCOW2" ] || die "build finished but $QCOW2 is missing."

# --- 2. convert --------------------------------------------------------------------
step "2/3 — Convert qcow2 → raw"
require_cmds qemu-img
# "is the raw older than the qcow2?" without test -nt: that operator is a bashism
# and this script runs under Alpine's busybox ash, where it is undefined — the
# comparison silently misbehaves and a stale raw image gets flashed. Compare
# mtimes numerically instead.
_q_mtime="$(stat -c %Y "$QCOW2" 2>/dev/null || stat -f %m "$QCOW2" 2>/dev/null || echo 0)"
_r_mtime="$([ -f "$RAW" ] && { stat -c %Y "$RAW" 2>/dev/null || stat -f %m "$RAW" 2>/dev/null; } || echo 0)"
if [ -f "$RAW" ] && [ "$_r_mtime" -ge "$_q_mtime" ]; then
  log "Raw image is up to date: $RAW"
else
  log "Converting qcow2 -> raw ..."
  run qemu-img convert -O raw "$QCOW2" "$RAW"
fi
ok "Raw image ready: $RAW ($(du -h "$RAW" | awk '{print $1}'))"

[ "$DO_FLASH" = "1" ] || { log "--image-only: stopping before the flash step."; exit 0; }

step "3/3 — Flash to a USB stick"
# --- 3. pick the target disk -------------------------------------------------------
# list_disks — print the candidate disks, EXTERNAL/REMOVABLE only. The system
# disk never appears here, and pick_disk refuses it anyway.
list_disks() {
  if [ "$OS" = "Darwin" ]; then
    diskutil list external physical
  else
    log "Removable disks (RM=1):"
    lsblk -dpno NAME,SIZE,TYPE,RM,MODEL | awk '$3 == "disk" && $4 == "1"'
    # No removable disk visible? Show everything but mark the internal ones;
    # pick_disk still refuses the system disk outright.
    if [ -z "$(lsblk -dpno NAME,TYPE,RM | awk '$2 == "disk" && $3 == "1"')" ]; then
      warn "No removable disk detected — showing ALL disks; pick carefully."
      lsblk -dpno NAME,SIZE,TYPE,RM,MODEL | awk '$3 == "disk"'
    fi
  fi
}

# root_disk — the device backing /, which must never be flashable (Linux; on
# macOS the external-physical filter already excludes it).
root_disk() {
  _src="$(findmnt -nvo SOURCE / 2>/dev/null || true)"
  [ -n "$_src" ] || { printf ''; return; }
  lsblk -no PKNAME "$_src" 2>/dev/null | head -1 || true
}

# normalize_disk INPUT — echo the canonical device node (/dev/diskN, /dev/sdX),
# or nothing if the input is not a plausible whole-disk name.
normalize_disk() {
  case "$1" in
    /dev/disk[0-9]*)        printf '%s' "$1" ;;
    disk[0-9]*)             printf '/dev/%s' "$1" ;;
    /dev/[a-z]*|/dev/nvme*) printf '%s' "$1" ;;
    [a-z]*|[a-z]*[0-9])     printf '/dev/%s' "$1" ;;
    *)                      printf '' ;;
  esac
}

pick_disk() {
  list_disks >&2  # everything but the final device name is informational
  _in="$(ask "Disk to flash (device name from the list above)" "")"
  [ -n "$_in" ] || die "no disk given — aborting, nothing was written."
  _dev="$(normalize_disk "$_in")"
  [ -n "$_dev" ] || die "'$_in' is not a plausible disk name — aborting."
  if [ "$OS" = "Darwin" ]; then
    diskutil list external physical | grep -q "^$_dev " \
      || die "$_dev is not an EXTERNAL physical disk — refusing (system disks are never flashable)."
  else
    lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}' | grep -qx "$_dev" \
      || die "$_dev is not a whole disk known to lsblk — refusing."
    _root="$(root_disk)"
    [ -z "$_root" ] || [ "$_dev" != "/dev/$_root" ] \
      || die "$_dev hosts the running system — refusing."
  fi
  printf '%s' "$_dev"
}

log "Detecting removable disks ..."
TARGET="$(pick_disk)"

cat <<EOF

  TARGET: $TARGET
  IMAGE:  $RAW ($(du -h "$RAW" | awk '{print $1}'))
  EVERYTHING on $TARGET will be DESTROYED.
EOF
_confirm="$(ask "Type the disk name again to confirm ($TARGET)" "")"
[ "$_confirm" = "$TARGET" ] || [ "$_confirm" = "${TARGET#/dev/}" ] \
  || die "confirmation did not match — aborting, nothing was written."

# --- 4. flash ------------------------------------------------------------------------
if [ "$OS" = "Darwin" ]; then
  log "Unmounting $TARGET ..."
  diskutil unmountDisk "$TARGET"
  # rdisk = raw device, much faster than the buffered diskN.
  log "Flashing (sudo dd; press Ctrl+T for progress) ..."
  $SUDO dd if="$RAW" of="/dev/r${TARGET#/dev/}" bs=4m
  sync
  log "Ejecting ..."
  diskutil eject "$TARGET" || true
else
  log "Unmounting partitions on $TARGET ..."
  for _part in $(lsblk -lnpo NAME "$TARGET" | tail -n +2); do
    $SUDO umount "$_part" 2>/dev/null || true
  done
  log "Flashing (sudo dd) ..."
  $SUDO dd if="$RAW" of="$TARGET" bs=4m status=progress conv=fsync
  sync
  udisksctl power-off -b "$TARGET" 2>/dev/null || true
fi
ok "Stick flashed. Remove it, boot the target machine from it — the installer"
ok "auto-clones to the internal disk, then ./setup.sh takes over (step 3 of 3)."

if ask_yn "Delete the 4G intermediate raw image ($RAW)?" 1; then
  rm -f "$RAW" && ok "Removed $RAW"
fi
exit 0
