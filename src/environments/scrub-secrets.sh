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
# Also removes the generated LUKS key note and the provisioning media (the
# cloud-init seed ISOs AND the Windows autounattend ISOs), which contain the
# plaintext guest password. (These are only read on a guest's first boot;
# recreating a VM regenerates them from config, so removing them is safe once the
# guests are provisioned — but detach them from the domains first if you want
# them gone from the VM definitions too.)
#
# NOTE: environments/isolate.sh now auto-ejects each cloud-init seed the moment
# cloud-init reports done (EJECT_SEEDS=1, the default), so in the normal flow the
# seeds are already gone by the time you run this. SCRUB_SEEDS=1 here is the
# belt-and-braces sweep: it also covers Windows unattend ISOs and any seed a
# guest had not finished consuming when isolate.sh last ran.
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
    # BOTH provisioning-media shapes carry the plaintext password: the Linux
    # cloud-init seed (<env>-seed.iso) and the Windows autounattend answer file
    # (<env>-unattend.iso). Sweep both. scrub-secrets.sh:40 used to name only the
    # seed, so a Windows env kept its plaintext-credential ISO attached forever.
    for media in "$IMAGES_DIR/${env}-seed.iso" "$IMAGES_DIR/${env}-unattend.iso"; do
      # The cdrom's target dev is auto-assigned by libvirt and is NOT always
      # 'sda' (q35 -> sata sda, i440fx -> ide hda). Detaching a hardcoded 'sda'
      # silently no-ops on i440fx, then rm leaves the domain XML pointing at a
      # now-missing ISO and `virsh start` fails. Discover the real target first.
      # `virsh domblklist` prints just two columns (Target, Source), so the
      # target device is $1 — reading $3 matched nothing, the detach silently
      # no-opped for EVERY domain, and the rm below then left the domain XML
      # pointing at a deleted ISO, which makes the next `virsh start` fail.
      tgt="$(virsh domblklist "$env" 2>/dev/null | awk -v f="$media" '$NF==f {print $1; exit}')"
      if [ -n "$tgt" ]; then
        # --config only (persistent XML), by design: a RUNNING domain keeps the
        # cdrom in its live XML until it is restarted and qemu holds the open fd,
        # so the ISO stays readable in-flight but the unlink below is safe. The
        # live-removal path is isolate.sh's auto-eject (which runs the moment
        # cloud-init is done); this manual scrub is the belt-and-braces sweep.
        virsh detach-disk "$env" "$tgt" --config 2>/dev/null \
          || warn "$env: could not detach seed cdrom '$tgt' — leaving $media in place."
      fi
      # Only remove the ISO once the PERSISTENT config no longer references it; a
      # dangling cdrom source is worse than a leftover file. (--inactive: a
      # running domain keeps the cdrom in its live XML until it is restarted, and
      # qemu holds the open fd, so unlinking now is safe.) shred: still plaintext.
      [ -e "$media" ] || continue
      if [ -z "$(virsh domblklist "$env" --inactive 2>/dev/null | awk -v f="$media" '$NF==f {print $1; exit}')" ]; then
        shred -u "$media" 2>/dev/null || rm -f "$media" 2>/dev/null || true
      fi
    done
  done
  log "Provisioning ISOs (cloud-init seed + Windows unattend) detached + shredded (SCRUB_SEEDS=1)."
fi

ok "Secrets scrubbed. config.env keeps only non-sensitive structure."
