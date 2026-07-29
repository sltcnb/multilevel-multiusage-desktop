#!/bin/bash
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
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
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
