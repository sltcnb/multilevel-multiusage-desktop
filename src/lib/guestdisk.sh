#!/bin/sh
# lib/guestdisk.sh
# -----------------------------------------------------------------------------
# Mount a SHUT-OFF guest's qcow2 from the host, with no help from the guest.
#
# Why this exists: every other tool we had for looking into (or repairing) a VM
# went through the qemu-guest-agent — and the agent is installed by cloud-init.
# So the one failure that matters most, "cloud-init did not provision this
# guest", took out the diagnosis and the repair path along with it: no agent, no
# password, no way in, and set-guest-password.sh could only say "is the VM
# running with the guest agent up?". This file breaks that circle. qemu-nbd
# exposes the disk as a block device on the host, so /etc/shadow and
# /var/log/cloud-init.log are ordinary files we can read and write.
#
# qemu-nbd ships in Alpine's qemu-img package, which the appliance already
# installs (src/build/make-image.sh), so this adds no new dependency.
#
# SAFETY: the caller MUST verify the domain is shut off. Attaching a qcow2 that
# a running qemu also has open gives an inconsistent view at best and corrupts
# the image at worst. gd_attach refuses to guess about that — see
# gd_require_off in the callers.
#
# Usage:
#   gd_attach /path/disk.qcow2 ro   # or rw
#   ... read/write under "$GD_MNT" ...
#   gd_detach
# -----------------------------------------------------------------------------

GD_NBD=""      # /dev/nbdN currently connected (empty when detached)
GD_MNT=""      # mountpoint of the guest root filesystem

# gd_supported — print nothing, return 0 if this host can do offline mounts.
gd_supported() {
  command -v qemu-nbd >/dev/null 2>&1 || return 1
  modprobe nbd max_part=16 2>/dev/null || true
  [ -b /dev/nbd0 ]
}

# gd_detach — always safe to call, including when nothing is attached. Kept
# idempotent because every caller wires it into a trap and it therefore runs
# again on the way out of an error path that already cleaned up.
gd_detach() {
  if [ -n "$GD_MNT" ] && mountpoint -q "$GD_MNT" 2>/dev/null; then
    umount "$GD_MNT" 2>/dev/null || umount -l "$GD_MNT" 2>/dev/null || true
  fi
  [ -n "$GD_MNT" ] && rmdir "$GD_MNT" 2>/dev/null
  if [ -n "$GD_NBD" ]; then
    qemu-nbd -d "$GD_NBD" >/dev/null 2>&1 || true
  fi
  GD_NBD=""; GD_MNT=""
  return 0
}

# _gd_free_nbd — first /dev/nbdN with no server attached. /sys/block/nbdN/pid
# only exists while a qemu-nbd process owns the device, which is the check
# qemu-nbd itself races on, so we test it rather than trusting nbd0 to be idle.
_gd_free_nbd() {
  _i=0
  while [ "$_i" -lt 16 ]; do
    if [ -b "/dev/nbd$_i" ] && [ ! -e "/sys/block/nbd$_i/pid" ]; then
      printf '/dev/nbd%s' "$_i"; return 0
    fi
    _i=$((_i+1))
  done
  return 1
}

# gd_attach DISK [ro|rw] — connect DISK and mount its ROOT filesystem at $GD_MNT.
#
# "Root filesystem" is found by probing, not by assuming a partition number: the
# Ubuntu cloud image puts root on p1 with a BIOS-grub p14 and an ESP p15, Debian
# uses p1, and Arch's cloudimg has an ESP ahead of root. A partition counts as
# root when it carries /etc/passwd — that also rejects the ESP, which would
# otherwise mount happily and read as an empty guest.
gd_attach() {
  _disk="$1"; _mode="${2:-ro}"
  [ -f "$_disk" ] || { warn "guestdisk: $_disk does not exist."; return 1; }
  gd_supported || {
    warn "guestdisk: qemu-nbd or the 'nbd' kernel module is unavailable — cannot inspect guest disks offline."
    return 1
  }
  GD_NBD="$(_gd_free_nbd)" || { warn "guestdisk: no free /dev/nbd* device."; return 1; }

  if [ "$_mode" = "rw" ]; then
    qemu-nbd -c "$GD_NBD" -f qcow2 "$_disk" >/dev/null 2>&1
  else
    qemu-nbd --read-only -c "$GD_NBD" -f qcow2 "$_disk" >/dev/null 2>&1
  fi || {
    warn "guestdisk: qemu-nbd could not attach $_disk (encrypted disk, or already in use by a running VM?)."
    GD_NBD=""; return 1
  }

  # The kernel scans the partition table asynchronously after connect; without
  # this the /dev/nbdNp* nodes are frequently not there yet on the first look.
  udevadm settle >/dev/null 2>&1 || sleep 1
  partprobe "$GD_NBD" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || sleep 1

  GD_MNT="$(mktemp -d)"
  for _p in "$GD_NBD"p* "$GD_NBD"; do
    [ -b "$_p" ] || continue
    if [ "$_mode" = "rw" ]; then
      mount "$_p" "$GD_MNT" 2>/dev/null || continue
    else
      mount -o ro "$_p" "$GD_MNT" 2>/dev/null || continue
    fi
    if [ -f "$GD_MNT/etc/passwd" ]; then return 0; fi
    umount "$GD_MNT" 2>/dev/null || true
  done

  warn "guestdisk: no partition on $_disk carries /etc/passwd — nothing to inspect."
  gd_detach
  return 1
}

# gd_require_off DOM — 0 when the domain exists and is not running. Everything
# in this file is unsafe against a live qemu, so callers gate on this and say so
# out loud rather than mounting anyway and hoping.
gd_require_off() {
  _st="$(virsh domstate "$1" 2>/dev/null | head -n1 | tr -d '\r')"
  case "$_st" in
    "shut off"|"") return 0 ;;
    *) return 1 ;;
  esac
}

# gd_domain_disk DOM — the domain's main writable disk (its qcow2). domblklist
# also lists the cloud-init seed CD-ROM, so select on the extension rather than
# taking the first row.
gd_domain_disk() {
  virsh domblklist "$1" 2>/dev/null | awk '$2 ~ /\.qcow2$/ {print $2; exit}'
}

# gd_domain_seed DOM — the seed ISO the domain has attached, if any.
gd_domain_seed() {
  virsh domblklist "$1" 2>/dev/null | awk '$2 ~ /seed\.iso$/ {print $2; exit}'
}

# -----------------------------------------------------------------------------
# gd_set_password MNT USER HASH [WITH_ROOT]
#   Set USER's password (a crypt HASH) in the guest root filesystem mounted at
#   MNT, creating the account with sudo rights if it does not exist. WITH_ROOT=1
#   gives root the same hash.
#
#   This is the login path that does NOT go through cloud-init. It is used both
#   to pre-seed a brand new disk (environments/create.sh) and to rescue a guest
#   cloud-init never provisioned (environments/guest-doctor.sh). Editing
#   /etc/shadow by hand is unglamorous, but it is the only method that still
#   works when the thing that was supposed to create the account did not run —
#   and being locked out of all three environments with no recovery is a worse
#   outcome than any elegance we would buy by insisting on the guest's own tools.
# -----------------------------------------------------------------------------
gd_set_password() {
  _mnt="$1"; _user="$2"; _hash="$3"; _with_root="${4:-1}"
  _pwf="$_mnt/etc/passwd"; _shf="$_mnt/etc/shadow"; _grf="$_mnt/etc/group"
  [ -f "$_pwf" ] && [ -f "$_shf" ] || { warn "guestdisk: $_mnt has no /etc/passwd+/etc/shadow."; return 1; }
  # shadow's "last changed" field, in days since the epoch. Leaving it EMPTY
  # means "must change password at next login", which would lock the operator
  # out again the moment they used the password we just set.
  _days="$(( $(date -u +%s) / 86400 ))"

  if awk -F: -v u="$_user" '$1==u {found=1} END {exit !found}' "$_pwf"; then
    # Account exists: replace the hash, reset the ageing fields.
    awk -F: -v u="$_user" -v h="$_hash" -v d="$_days" 'BEGIN{OFS=":"}
      $1==u { $2=h; $3=d; $5=99999 } {print}' "$_shf" > "$_shf.tmp" \
      && cat "$_shf.tmp" > "$_shf"
    rm -f "$_shf.tmp"
  else
    # Account missing: create it. First free uid at or above 1000, its own
    # group, a home directory from /etc/skel, and passwordless sudo — the same
    # shape the cloud-init seed would have produced.
    _uid=1000
    while awk -F: -v i="$_uid" '$3==i {found=1} END {exit !found}' "$_pwf"; do _uid=$((_uid+1)); done
    printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$_user" "$_uid" "$_uid" "$_user" >> "$_pwf"
    printf '%s:x:%s:\n' "$_user" "$_uid" >> "$_grf"
    printf '%s:%s:%s:0:99999:7:::\n' "$_user" "$_hash" "$_days" >> "$_shf"
    mkdir -p "$_mnt/home/$_user" 2>/dev/null
    cp -a "$_mnt/etc/skel/." "$_mnt/home/$_user/" 2>/dev/null || true
    chown -R "$_uid:$_uid" "$_mnt/home/$_user" 2>/dev/null || true
    chmod 750 "$_mnt/home/$_user" 2>/dev/null || true
    # Admin group: apt images ship sudo/adm, the Arch image ships wheel. Join
    # whichever actually exist rather than inventing one sudoers ignores.
    for _g in sudo adm wheel; do
      awk -F: -v g="$_g" '$1==g {found=1} END {exit !found}' "$_grf" || continue
      gd_group_add "$_grf" "$_g" "$_user"
    done
    mkdir -p "$_mnt/etc/sudoers.d" 2>/dev/null
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$_user" > "$_mnt/etc/sudoers.d/90-appliance-$_user"
    chmod 440 "$_mnt/etc/sudoers.d/90-appliance-$_user" 2>/dev/null || true
  fi

  if [ "$_with_root" = "1" ]; then
    awk -F: -v h="$_hash" -v d="$_days" 'BEGIN{OFS=":"}
      $1=="root" { $2=h; $3=d; $5=99999 } {print}' "$_shf" > "$_shf.tmp" \
      && cat "$_shf.tmp" > "$_shf"
    rm -f "$_shf.tmp"
  fi

  # /etc/shadow must never become world-readable. cat-into-place kept the
  # original inode and mode, but be explicit — a file we created ourselves would
  # otherwise carry our umask.
  chmod 640 "$_shf" 2>/dev/null || true
  return 0
}

# gd_group_add GROUPFILE GROUP USER — add USER to GROUP's member list in an
# offline /etc/group, idempotently. The comma-wrapped index test is what stops
# "sudo" matching inside "sudoers" and stops a second run duplicating the name.
gd_group_add() {
  _gf="$1"; _g="$2"; _u="$3"
  awk -F: -v g="$_g" -v u="$_u" 'BEGIN{OFS=":"}
    $1==g { if ($4=="") $4=u; else if (index(","$4",", ","u",")==0) $4=$4","u }
    {print}' "$_gf" > "$_gf.tmp" && cat "$_gf.tmp" > "$_gf"
  rm -f "$_gf.tmp"
}

# -----------------------------------------------------------------------------
# gd_seed_network MNT OSFAMILY
#   Write a "DHCP on any ethernet" network config straight into the guest root
#   filesystem mounted at MNT, so the NIC comes up WITHOUT cloud-init.
#
#   Same rationale as gd_set_password: networking that works only if cloud-init's
#   network module succeeds is a single point of failure — and it has been seen
#   to fail, leaving the interface up-but-unconfigured (IPv6 link-local only, no
#   IPv4, no route). Everything downstream then dies: no DHCP lease -> no default
#   route -> "network unreachable" -> apt cannot reach the repos -> no
#   qemu-guest-agent, no desktop, and a boot that stalls waiting on
#   network-online.target for its full timeout.
#
#   Two things are written:
#     1. The renderer's own DHCP config (netplan for apt distros, a
#        systemd-networkd .network for Arch). `optional: true` / no wait keeps a
#        momentarily-down link from dragging the boot out.
#     2. /etc/cloud/cloud.cfg.d/99-appliance-disable-network.cfg turning cloud-
#        init network management OFF, so cloud-init does not ALSO emit a config
#        that fights ours over the same interface (a double match breaks netplan).
#
#   OSFAMILY is os_family's output: "apt" (ubuntu/debian) or anything else (arch).
#   Matching is by glob (e*/en*/eth*), never a hardcoded ens3: the interface name
#   depends on the machine type, and pinning one is exactly the kind of breakage
#   this function exists to avoid.
# -----------------------------------------------------------------------------
gd_seed_network() {
  _mnt="$1"; _fam="$2"
  [ -d "$_mnt/etc" ] || { warn "guestdisk: $_mnt has no /etc — cannot seed networking."; return 1; }

  # Take networking out of cloud-init's hands so it cannot emit a competing
  # config. This file is read by every cloud-init version.
  mkdir -p "$_mnt/etc/cloud/cloud.cfg.d" 2>/dev/null
  printf 'network: {config: disabled}\n' \
    > "$_mnt/etc/cloud/cloud.cfg.d/99-appliance-disable-network.cfg"

  if [ "$_fam" = "apt" ]; then
    # netplan (renderer networkd — the cloud/server default). Files apply in
    # lexical order and later wins, so 99- overrides any 50-cloud-init.yaml that
    # is already there. 0600: netplan warns (and future versions may refuse) on
    # a world-readable config.
    mkdir -p "$_mnt/etc/netplan" 2>/dev/null
    ( umask 077
      cat > "$_mnt/etc/netplan/99-appliance-dhcp.yaml" <<'NP'
network:
  version: 2
  renderer: networkd
  ethernets:
    appliance-dhcp:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: false
      optional: true
NP
    )
  else
    # systemd-networkd. Among matching .network files networkd applies the
    # lexically FIRST, so a low number (05-) makes ours authoritative over any
    # image default like 20-ethernet.network.
    mkdir -p "$_mnt/etc/systemd/network" 2>/dev/null
    cat > "$_mnt/etc/systemd/network/05-appliance-dhcp.network" <<'ND'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCP]
RouteMetric=100
ND
    # Make sure networkd + resolved actually run — the offline equivalent of
    # `systemctl enable systemd-networkd systemd-resolved`. Best-effort: the Arch
    # cloud image usually enables them already, and a stale symlink is harmless.
    _ulib="/usr/lib/systemd/system"
    mkdir -p "$_mnt/etc/systemd/system/multi-user.target.wants" \
             "$_mnt/etc/systemd/system/sockets.target.wants" 2>/dev/null
    ln -sf "$_ulib/systemd-networkd.service" \
       "$_mnt/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null
    ln -sf "$_ulib/systemd-networkd.socket" \
       "$_mnt/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" 2>/dev/null
    ln -sf "$_ulib/systemd-resolved.service" \
       "$_mnt/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" 2>/dev/null
    # DNS via resolved's stub, so name resolution works once the link is up.
    ln -sf /run/systemd/resolve/stub-resolv.conf "$_mnt/etc/resolv.conf" 2>/dev/null || true
  fi
  return 0
}
