#!/bin/bash
# =============================================================================
# environments/create.sh
# -----------------------------------------------------------------------------
# Create the three VMs with virt-install:
#   desktop  -> Ubuntu cloud image + cloud-init (unattended)
#   devops   -> Arch  (prebuilt Arch cloud image + cloud-init — see prose)
#   analysis -> Arch  (same)
#
# Auto-computed vCPU/RAM/disk (from config.env). host-passthrough CPU mode.
# Each VM attached to its OWN isolated network. virsh autostart on all three.
#
# NOTE: this script ENSURES each isolated network exists (idempotent) so VMs can
# attach. environments/isolate.sh owns the authoritative network definitions,
# the nftables inter-VM DROP rules, and the verification test. Running 03 before
# 05 is fine; 05 re-applies/repairs.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config
require_cmds virt-install virsh qemu-img wget openssl

mkdir -p "$IMAGES_DIR" "$CACHE_DIR"

# -----------------------------------------------------------------------------
# Tunable image sources (OVERRIDABLE).
# -----------------------------------------------------------------------------
: "${UBUNTU_IMG_URL:=https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}"
# Arch publishes an official cloud image (qcow2) that ships cloud-init.
: "${ARCH_IMG_URL:=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2}"
# Debian official genericcloud qcow2 (bookworm) — ships cloud-init.
: "${DEBIAN_IMG_URL:=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"

# -----------------------------------------------------------------------------
# Guest password: empty or "generate" -> auto-generate (recorded in
# /root/generated-secrets.txt). Then hash it for cloud-init (no plaintext baked).
# -----------------------------------------------------------------------------
GUEST_PASSWORD="$(resolve_secret GUEST_PASSWORD)"
PW_HASH="$(openssl passwd -6 "$GUEST_PASSWORD")"

# -----------------------------------------------------------------------------
# ensure_net NAME BRIDGE SUBNET  — define+start an ISOLATED NAT network.
#   forward mode 'nat' gives outbound internet; each net has its own bridge and
#   its own /24 so guests are on separate L2 segments. 05 adds nftables to block
#   inter-net L3 forwarding (defense-in-depth).
# -----------------------------------------------------------------------------
ensure_net() {
  name="$1"; bridge="$2"; subnet="$3"
  if virsh net-info "$name" >/dev/null 2>&1; then
    log "Network $name exists."
  else
    log "Defining isolated network $name ($bridge, ${subnet}.0/24) ..."
    tmpxml="$(mktemp)"
    cat > "$tmpxml" <<EOF
<network>
  <name>$name</name>
  <forward mode='nat'/>
  <bridge name='$bridge' stp='on' delay='0'/>
  <ip address='${subnet}.1' netmask='255.255.255.0'>
    <dhcp><range start='${subnet}.2' end='${subnet}.254'/></dhcp>
  </ip>
</network>
EOF
    virsh net-define "$tmpxml"
    rm -f "$tmpxml"
  fi
  virsh net-start "$name" 2>/dev/null || true
  virsh net-autostart "$name" 2>/dev/null || true
}

# Ensure an isolated network for every ENABLED environment (index -> subnet).
for_each_enabled_env | while read -r env idx; do
  ensure_net "$(env_net "$env")" "$(env_bridge "$env" "$idx")" "$(env_subnet "$env" "$idx")"
done

# -----------------------------------------------------------------------------
# make_seed VMNAME HOSTNAME  -> path to a cloud-init NoCloud seed ISO.
#   Works for BOTH Ubuntu and Arch cloud images (both bundle cloud-init).
# -----------------------------------------------------------------------------
make_seed() {
  vm="$1"; host="$2"
  seed_dir="$CACHE_DIR/seed-$vm"
  mkdir -p "$seed_dir"

  # ---- Desktop environment (config <env>_DE) --------------------------------
  # Cloud-init installs the chosen DE + display manager + autologin so the env
  # boots into a usable desktop. Works for BOTH Ubuntu (apt) and Arch (pacman) —
  # cloud-init abstracts the package manager; package NAMES differ per distro.
  # "none" keeps the env CLI-only. Both distros are systemd, so the DM enable +
  # graphical target + lightdm autologin are identical.
  de_pkg_lines="  - qemu-guest-agent"
  de_runcmd_lines="  - systemctl enable --now qemu-guest-agent || true"
  _os="$(env_val "$vm" OS arch)"; _de="$(env_val "$vm" DE none)"
  if [ "$_de" != "none" ]; then
    case "$_os" in
      ubuntu)
        case "${_de}" in
          xfce4) _pk="xubuntu-desktop-minimal lightdm"; _dm="lightdm"; _sess="xfce" ;;
          gnome) _pk="ubuntu-desktop-minimal gdm3";      _dm="gdm3";    _sess="ubuntu" ;;
          kde)   _pk="kde-plasma-desktop sddm";          _dm="sddm";    _sess="plasma" ;;
          mate)  _pk="ubuntu-mate-desktop lightdm";      _dm="lightdm"; _sess="mate" ;;
          lxqt)  _pk="lubuntu-desktop sddm";             _dm="sddm";    _sess="lxqt" ;;
          *) warn "Unknown DE '$_de'; defaulting to xfce4."; _pk="xubuntu-desktop-minimal lightdm"; _dm="lightdm"; _sess="xfce" ;;
        esac ;;
      debian)   # Debian package names (apt)
        case "${_de}" in
          xfce4) _pk="xorg xfce4 xfce4-goodies lightdm";  _dm="lightdm"; _sess="xfce" ;;
          gnome) _pk="gnome-core gdm3";                    _dm="gdm3";    _sess="gnome" ;;
          kde)   _pk="kde-plasma-desktop sddm";            _dm="sddm";    _sess="plasma" ;;
          mate)  _pk="mate-desktop-environment lightdm";   _dm="lightdm"; _sess="mate" ;;
          lxqt)  _pk="lxqt sddm";                          _dm="sddm";    _sess="lxqt" ;;
          *) warn "Unknown DE '$_de'; defaulting to xfce4."; _pk="xorg xfce4 lightdm"; _dm="lightdm"; _sess="xfce" ;;
        esac ;;
      *)        # arch (Arch package names + explicit xorg group)
        case "${_de}" in
          xfce4) _pk="xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"; _dm="lightdm"; _sess="xfce" ;;
          gnome) _pk="gnome gdm";                                            _dm="gdm";     _sess="gnome" ;;
          kde)   _pk="plasma-meta sddm";                                     _dm="sddm";    _sess="plasma" ;;
          mate)  _pk="xorg mate mate-extra lightdm lightdm-gtk-greeter";     _dm="lightdm"; _sess="mate" ;;
          lxqt)  _pk="xorg lxqt sddm";                                       _dm="sddm";    _sess="lxqt" ;;
          *) warn "Unknown DE '$_de'; defaulting to xfce4."; _pk="xorg xfce4 lightdm lightdm-gtk-greeter"; _dm="lightdm"; _sess="xfce" ;;
        esac ;;
    esac
    for p in $_pk; do de_pkg_lines="$de_pkg_lines
  - $p"; done
    de_runcmd_lines="$de_runcmd_lines
  - systemctl set-default graphical.target || true
  - systemctl enable $_dm || true"
    # Autologin (lightdm is scriptable simply; gdm/sddm best-effort).
    if [ "$_dm" = "lightdm" ]; then
      de_runcmd_lines="$de_runcmd_lines
  - mkdir -p /etc/lightdm
  - printf '[Seat:*]\\nautologin-user=$GUEST_USER\\nautologin-session=$_sess\\n' > /etc/lightdm/lightdm.conf"
    fi
    log "$vm DE ($_os): $_de -> $_pk"
  fi

  # ---- Microsoft Intune enrollment prep (<env>_INTUNE=1, Ubuntu only) --------
  # Installs the Microsoft repo + intune-portal (+ Edge, pulled in). Enrollment
  # itself is INTERACTIVE: after boot, open "Microsoft Intune" in the desktop and
  # sign in with Entra (device compliance). We only pre-install the tooling.
  if [ "$(env_val "$vm" INTUNE 0)" = "1" ]; then
    if [ "$_os" = "ubuntu" ]; then
      de_runcmd_lines="$de_runcmd_lines
  - curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
  - sh -c 'echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main\" > /etc/apt/sources.list.d/microsoft-prod.list'
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get install -y intune-portal
  - systemctl enable microsoft-identity-broker 2>/dev/null || true"
      log "$vm: Intune prep queued (enroll interactively after boot)."
    else
      warn "$vm: INTUNE=1 ignored — Intune enrollment is Ubuntu-only (this env is $_os)."
    fi
  fi

  # ---- Microsoft apps: Teams + Outlook as Edge PWAs (<env>_MSAPPS=1) ---------
  # MS dropped the native Linux Teams; the community teams-for-linux wrapper works
  # but is an UNMANAGED client that Entra Conditional Access often blocks. Since
  # this is an Intune-enrolled device, we install Teams AND Outlook as PWAs inside
  # the managed Edge — that's the Conditional-Access-compliant path. (apt distros.)
  if [ "$(env_val "$vm" MSAPPS 0)" = "1" ] && [ "$(os_family "$_os")" = "apt" ]; then
    de_runcmd_lines="$de_runcmd_lines
  - curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
  - sh -c 'echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main\" > /etc/apt/sources.list.d/microsoft-edge.list'
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get install -y microsoft-edge-stable
  - sh -c 'printf \"[Desktop Entry]\\nName=Outlook\\nExec=microsoft-edge-stable --app=https://outlook.office.com\\nType=Application\\nIcon=microsoft-edge\\nCategories=Office;Network;\\n\" > /usr/share/applications/outlook.desktop'
  - sh -c 'printf \"[Desktop Entry]\\nName=Microsoft Teams\\nExec=microsoft-edge-stable --app=https://teams.microsoft.com\\nType=Application\\nIcon=microsoft-edge\\nCategories=Office;Network;\\n\" > /usr/share/applications/teams.desktop'"
    log "$vm: Outlook + Teams (Edge PWAs, Conditional-Access compliant) queued."
  fi

  # ---- Wazuh agent auto-enroll (<env>_WAZUH=1 + WAZUH_MANAGER) ----------------
  # Installs + registers the Wazuh agent pointing at WAZUH_MANAGER. Ubuntu via the
  # Wazuh apt repo; Arch via AUR (best-effort, needs base-devel + network).
  wm="${WAZUH_MANAGER:-}"
  if [ "$(env_val "$vm" WAZUH 0)" = "1" ]; then
    if [ -z "$wm" ]; then
      warn "$vm: WAZUH=1 but WAZUH_MANAGER is empty — skipping."
    elif [ "$(os_family "$_os")" = "apt" ]; then
      de_runcmd_lines="$de_runcmd_lines
  - curl -sSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  - sh -c 'echo \"deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main\" > /etc/apt/sources.list.d/wazuh.list'
  - apt-get update
  - sh -c 'WAZUH_MANAGER=\"$wm\" DEBIAN_FRONTEND=noninteractive apt-get install -y wazuh-agent'
  - systemctl enable --now wazuh-agent"
      log "$vm: Wazuh agent -> $wm (apt)."
    else   # arch (AUR, best-effort)
      de_runcmd_lines="$de_runcmd_lines
  - pacman -Sy --noconfirm --needed base-devel git
  - su - $GUEST_USER -c 'git clone https://aur.archlinux.org/wazuh-agent.git /tmp/wz && cd /tmp/wz && makepkg -si --noconfirm'
  - sed -i 's|<address>.*</address>|<address>$wm</address>|' /var/ossec/etc/ossec.conf
  - systemctl enable --now wazuh-agent"
      log "$vm: Wazuh agent -> $wm (AUR, best-effort)."
    fi
  fi

  cat > "$seed_dir/meta-data" <<EOF
instance-id: $vm
local-hostname: $host
EOF
  cat > "$seed_dir/user-data" <<EOF
#cloud-config
hostname: $host
users:
  - name: $GUEST_USER
    groups: [wheel, sudo, adm]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
ssh_pwauth: true
# Set the password as PLAINTEXT via chpasswd (cloud-init hashes it internally).
# This is the most portable form — the users[].passwd hash field is handled
# inconsistently across cloud-init versions (Ubuntu's rejected our SHA-512 hash
# while Arch accepted it). type: text avoids all hash-format issues.
chpasswd:
  expire: false
  users:
    - name: $GUEST_USER
      password: "$GUEST_PASSWORD"
      type: text
# Package install differs per distro but cloud-init abstracts it.
package_update: true
packages:
$de_pkg_lines
runcmd:
$de_runcmd_lines
# NOTE: no shared-folder / no cross-VM anything provisioned here (isolation).
EOF
  # Build the NoCloud seed ISO. Prefer cloud-localds; else xorriso's mkisofs
  # (installed via virt-install on Alpine); else genisoimage (Debian path).
  # The volume label MUST be "cidata" for cloud-init NoCloud to pick it up.
  seed_iso="$IMAGES_DIR/${vm}-seed.iso"
  if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "$seed_iso" "$seed_dir/user-data" "$seed_dir/meta-data"
  elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -output "$seed_iso" -volid cidata -joliet -rock \
      "$seed_dir/user-data" "$seed_dir/meta-data"
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -o "$seed_iso" -V cidata -J -r \
      "$seed_dir/user-data" "$seed_dir/meta-data"
  elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "$seed_iso" -volid cidata -joliet -rock \
      "$seed_dir/user-data" "$seed_dir/meta-data"
  else
    die "No ISO builder found (cloud-localds/mkisofs/xorriso/genisoimage)."
  fi
  echo "$seed_iso"
}

# -----------------------------------------------------------------------------
# fetch  URL DEST — download once (idempotent cache).
# -----------------------------------------------------------------------------
fetch() {
  url="$1"; dest="$2"
  if [ -f "$dest" ]; then log "Cached: $(basename "$dest")"; return; fi
  log "Downloading $(basename "$dest") ..."
  wget -O "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

# -----------------------------------------------------------------------------
# create_vm  NAME VARIANT NET VCPU RAM DISKGB BASEIMG HOSTNAME
#   Copies base cloud image to a per-VM disk, resizes, attaches cloud-init seed,
#   imports with virt-install (no interactive install — image is prebuilt).
#   CPU host-passthrough. SPICE graphics (software render; no GPU passthrough).
# -----------------------------------------------------------------------------
create_vm() {
  name="$1"; variant="$2"; net="$3"; vcpu="$4"; ram="$5"; disk="$6"; base="$7"; host="$8"

  if virsh dominfo "$name" >/dev/null 2>&1; then
    warn "VM $name already exists — skipping create (idempotent)."
    virsh autostart "$name" 2>/dev/null || true
    return
  fi

  vmdisk="$IMAGES_DIR/${name}.qcow2"
  # Per-env user-keyed encryption (ANSSI): <env>_ENCRYPT_DISK=1 makes this VM's
  # disk a LUKS-encrypted qcow2, unlocked by <env>_DISK_PASS (a secret the user
  # sets). libvirt holds the secret to start the domain; scrub-secrets blanks
  # <env>_DISK_PASS from config afterward. EXPERIMENTAL.
  disk_opts="path=$vmdisk,format=qcow2,bus=virtio"
  if [ "$(env_val "$name" ENCRYPT_DISK 0)" = "1" ]; then
    dpass="$(env_val "$name" DISK_PASS)"
    if [ -z "$dpass" ] || [ "$dpass" = "generate" ]; then
      dpass="$(gen_secret)"; set_kv "${name}_DISK_PASS" "$dpass"
      umask 077; printf '%s_DISK_PASS=%s\n' "$name" "$dpass" >> /root/generated-secrets.txt 2>/dev/null || true
      warn "$name: generated per-env disk passphrase -> /root/generated-secrets.txt"
    fi
    log "Preparing ENCRYPTED disk for $name (LUKS, ${disk}G) ..."
    # Flatten base -> LUKS-encrypted qcow2 (no backing: luks+backing is unsupported).
    secpath="$IMAGES_DIR/.${name}.pass"; umask 077; printf '%s' "$dpass" > "$secpath"
    qemu-img convert -O qcow2 -o "encrypt.format=luks,encrypt.key-secret=sec0" \
      --object "secret,id=sec0,file=$secpath" "$base" "$vmdisk"
    qemu-img resize --object "secret,id=sec0,file=$secpath" \
      "encrypt.key-secret=sec0" "$vmdisk" "${disk}G" 2>/dev/null || qemu-img resize "$vmdisk" "${disk}G" 2>/dev/null || true
    # Define a libvirt secret so the domain can unlock the disk at start.
    secuuid="$(printf '%s' "$name" | md5sum | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\).*/\1-\2-\3-\4-\5/')"
    cat > /tmp/sec-$name.xml <<SX
<secret ephemeral='no' private='yes'>
  <uuid>$secuuid</uuid>
  <usage type='volume'><volume>$vmdisk</volume></usage>
</secret>
SX
    virsh secret-define /tmp/sec-$name.xml >/dev/null 2>&1 || true
    virsh secret-set-value "$secuuid" --base64 "$(printf '%s' "$dpass" | base64)" >/dev/null 2>&1 || true
    rm -f /tmp/sec-$name.xml "$secpath"
    disk_opts="path=$vmdisk,format=qcow2,bus=virtio,driver.type=qcow2,encryption.format=luks,encryption.secret.type=passphrase,encryption.secret.uuid=$secuuid"
  else
    log "Preparing disk for $name (${disk}G) ..."
    qemu-img create -f qcow2 -F qcow2 -b "$base" "$vmdisk"   # backing = base cloud img (thin)
    qemu-img resize "$vmdisk" "${disk}G"
  fi

  seed_iso="$(make_seed "$name" "$host")"

  log "virt-install $name (vcpu=$vcpu ram=${ram}MB net=$net) ..."
  # --import: boot the prebuilt image; no OS installer runs. cloud-init in the
  # image consumes the NoCloud seed on first boot => unattended provisioning.
  virt-install \
    --name "$name" \
    --os-variant "$variant" \
    --memory "$ram" \
    --vcpus "$vcpu" \
    --cpu host-passthrough \
    --import \
    --disk "$disk_opts" \
    --disk path="$seed_iso",device=cdrom \
    --network network="$net",model=virtio \
    --graphics spice \
    --video qxl \
    --channel spicevmc \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --noautoconsole \
    --wait 0
    # The org.qemu.guest_agent.0 channel lets the host talk to qemu-guest-agent
    # in the guest — needed for isolate.sh's in-guest verification.
    # TODO(GPU-passthrough): replace --graphics spice/--video qxl with
    #   --graphics none --hostdev <PCI-of-GPU>,address.type=pci  (VFIO)
    # and bind the GPU to vfio-pci on the host. Only ONE VM can own the single
    # physical GPU at a time on one monitor.

  virsh autostart "$name"
  ok "$name created + autostart enabled."
}

# -----------------------------------------------------------------------------
# Download only the base image(s) actually needed by the enabled envs' OSes.
# -----------------------------------------------------------------------------
need_ubuntu=0; need_arch=0; need_debian=0
for pair in $(for_each_enabled_env | awk '{print $1}'); do
  case "$(env_val "$pair" OS arch)" in ubuntu) need_ubuntu=1;; arch) need_arch=1;; debian) need_debian=1;; esac
done
[ "$need_ubuntu" = 1 ] && fetch "$UBUNTU_IMG_URL" "$IMAGES_DIR/base-ubuntu.img"
[ "$need_arch"   = 1 ] && fetch "$ARCH_IMG_URL"   "$IMAGES_DIR/base-arch.qcow2"
[ "$need_debian" = 1 ] && fetch "$DEBIAN_IMG_URL" "$IMAGES_DIR/base-debian.qcow2"

# ENTRA/INTUNE constraint: any env with INTUNE=1 MUST be Ubuntu (Intune Linux
# enrollment is Ubuntu-only). Enforce so the office/desktop stays Ubuntu.
for pair in $(for_each_enabled_env | awk '{print $1}'); do
  if [ "$(env_val "$pair" INTUNE 0)" = "1" ] && [ "$(env_val "$pair" OS arch)" != "ubuntu" ]; then
    die "$pair has INTUNE=1 but OS=$(env_val "$pair" OS) — Intune/Entra requires Ubuntu. Set ${pair}_OS=ubuntu."
  fi
done

# -----------------------------------------------------------------------------
# Build every ENABLED environment. OS -> base image + os-variant. Resource sizes
# and the isolated network come from config (written by 01 / ensured above).
# -----------------------------------------------------------------------------
for_each_enabled_env | while read -r env idx; do
  os="$(env_val "$env" OS arch)"
  base="$(os_base "$os")" || { warn "Unsupported OS '$os' for $env (use ubuntu|arch|debian); skipping."; continue; }
  create_vm "$env" "$(os_variant "$os")" "$(env_net "$env")" \
            "$(env_val "$env" VCPU 1)" "$(env_val "$env" RAM_MB 1024)" \
            "$(env_val "$env" DISK_GB 10)" "$base" "$env"
done

ok "All enabled VMs created."
virsh list --all
cat <<EOF

MANUAL: first boot of each VM runs cloud-init (1-2 min). Watch with:
    virsh console <name>     (Ctrl+] to exit)
Next: ./host/switching.sh  then  ./environments/isolate.sh
EOF
