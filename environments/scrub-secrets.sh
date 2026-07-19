#!/bin/bash
# =============================================================================
# environments/scrub-secrets.sh — remove secrets from the appliance after setup
# -----------------------------------------------------------------------------
# Run this LAST, once the environments are created, isolated, and (optionally)
# their VPNs are up. It blanks every secret in config.env (guest password, WiFi
# PSK, LUKS passphrase, WireGuard private keys) — they've already been consumed
# (baked into the VMs / hashed into wpa_supplicant / applied to LUKS+wg), so the
# appliance no longer needs them at rest. Structural config is kept.
#
# Also removes the generated LUKS key note and the cloud-init seed ISOs, which
# contain the plaintext guest password. (Seeds are only read on a guest's first
# boot; recreating a VM regenerates them from config, so removing them is safe
# once the guests are provisioned — but detach them from the domains first if you
# want them gone from the VM definitions too.)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config

log "Scrubbing secrets from config.env ..."
scrub_secrets

# Remove the generated-secrets records (record them elsewhere FIRST!).
for f in /root/luks-key.txt /root/generated-secrets.txt; do
  if [ -f "$f" ]; then
    warn "Removing $f — make sure you recorded everything in it!"
    shred -u "$f" 2>/dev/null || rm -f "$f"
  fi
done

# Optionally wipe seed ISOs (plaintext password). Off by default because they are
# attached to the domains as cdrom; set SCRUB_SEEDS=1 to detach+remove.
if [ "${SCRUB_SEEDS:-0}" = "1" ]; then
  for_each_enabled_env | while read -r env _; do
    virsh detach-disk "$env" sda --config 2>/dev/null || true
    rm -f "$IMAGES_DIR/${env}-seed.iso" 2>/dev/null || true
  done
  log "Seed ISOs detached + removed (SCRUB_SEEDS=1)."
fi

ok "Secrets scrubbed. config.env keeps only non-sensitive structure."
