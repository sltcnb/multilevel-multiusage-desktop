#!/bin/bash
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
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
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
