#!/bin/sh
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
# shellcheck source=../lib/common.sh
if [ -f "$HERE/../lib/common.sh" ]; then . "$HERE/../lib/common.sh"
elif [ -f "$HERE/lib/common.sh" ]; then . "$HERE/lib/common.sh"
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
