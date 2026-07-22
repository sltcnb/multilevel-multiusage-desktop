# nix/modules/appliance/guests.nix
# -----------------------------------------------------------------------------
# The guests — declarative-ish equivalent of environments/create.sh.
#
# Guests stay OS-vendor cloud images provisioned by cloud-init (deliberate:
# office MUST be Ubuntu for Intune/Entra, and cloud-init keeps every OS on one
# uniform path). The HOST is NixOS; it only DECLARES the domains.
#
# What is pure Nix here: the cloud-init user-data/meta-data (minus the password)
# and the option surface. What stays a first-boot systemd oneshot: hardware-
# dependent resource split, fetching the (rolling "latest") base images, seed
# ISO + qcow2 overlay creation, and `virsh define`. That impurity is inherent —
# NixOS cannot know the machine's RAM/disk at eval time.
#
# MVP scope: domains are defined, isolated and started (enough to demonstrate
# switching + isolation + the trust bar). Full parity with create.sh's
# self-healing DE installer, Intune/MSApps/Wazuh and per-VM LUKS is a TODO.
# -----------------------------------------------------------------------------
{ config, lib, pkgs, applianceLib, ... }:
let
  inherit (lib) mkIf mkOption types concatMapStringsSep optionalString;
  cfg = config.appliance;
  gcfg = cfg.guest;

  enabled = applianceLib.enabledViews cfg.subnetBase cfg.environments;

  # Best-effort in-guest desktop install. Full parity (self-healing retry loop,
  # display-manager autologin, MS/Wazuh integrations) lives in create.sh — TODO.
  deRuncmd = v:
    if v.desktop == "none" then ""
    else if v.osFamily == "apt" then
      "  - [ sh, -c, \"DEBIAN_FRONTEND=noninteractive apt-get install -y ${v.desktop} || true\" ]"
    else
      "  - [ sh, -c, \"pacman -Sy --noconfirm ${v.desktop} || true\" ]";

  mkUserData = v: pkgs.writeText "user-data-${v.name}" ''
    #cloud-config
    hostname: ${v.name}
    users:
      - name: ${gcfg.user}
        sudo: ALL=(ALL) NOPASSWD:ALL
        lock_passwd: false
        shell: /bin/bash
        groups: [${if v.osFamily == "apt" then "sudo, adm" else "wheel"}]
    ssh_pwauth: true
    chpasswd:
      expire: false
      list: |
        ${gcfg.user}:__GUEST_PASSWORD__
        root:__GUEST_PASSWORD__
    package_update: true
    packages:
      - qemu-guest-agent
    runcmd:
      - [ sh, -c, "systemctl enable --now qemu-guest-agent || true" ]
    ${deRuncmd v}
    power_state:
      mode: reboot
      timeout: 60
      condition: true
  '';

  mkMetaData = v: pkgs.writeText "meta-data-${v.name}" ''
    instance-id: ${v.name}
    local-hostname: ${v.name}
  '';

  # libvirt domain XML template (SPICE + QXL + virtio + guest-agent channel).
  # Placeholders are substituted at runtime with sed — a heredoc would break
  # under Nix's '' indentation stripping (the EOF terminator wouldn't land at
  # column 0). The guest-agent channel is what isolate.sh's checks talk to.
  domainTemplate = pkgs.writeText "appliance-domain.xml" ''
    <domain type='kvm'>
      <name>@NAME@</name>
      <memory unit='MiB'>@RAM@</memory>
      <vcpu>@VCPU@</vcpu>
      <os><type arch='x86_64' machine='q35'>hvm</type><boot dev='hd'/></os>
      <features><acpi/><apic/></features>
      <cpu mode='host-passthrough'/>
      <clock offset='utc'/>
      <devices>
        <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2'/>
          <source file='@VMDISK@'/>
          <target dev='vda' bus='virtio'/>
        </disk>
        <disk type='file' device='cdrom'>
          <driver name='qemu' type='raw'/>
          <source file='@SEED@'/>
          <target dev='sda' bus='sata'/>
          <readonly/>
        </disk>
        <interface type='network'>
          <source network='@NET@'/>
          <model type='virtio'/>
        </interface>
        <graphics type='spice' autoport='yes'><listen type='address' address='127.0.0.1'/></graphics>
        <video><model type='qxl'/></video>
        <channel type='spicevmc'><target type='virtio' name='com.redhat.spice.0'/></channel>
        <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
      </devices>
    </domain>
  '';

  # Per-env provisioning invocation. Overrides pass through as "-" when null.
  orDash = x: if x == null then "-" else toString x;
  provisionCalls = concatMapStringsSep "\n"
    (v: ''provision_env "${v.name}" "${v.os}" "${v.netName}" \
      "${mkUserData v}" "${mkMetaData v}" \
      "${orDash v.memoryMB}" "${orDash v.vcpus}" "${orDash v.diskGB}"'')
    enabled;

  provisionGuests = pkgs.writeShellApplication {
    name = "appliance-provision-guests";
    runtimeInputs = with pkgs; [ libvirt qemu cloud-utils curl coreutils gnused gawk ];
    text = ''
      set -euo pipefail
      IMAGES_DIR="${cfg.images.dir}"
      CACHE_DIR="${cfg.cache.dir}"
      mkdir -p "$IMAGES_DIR" "$CACHE_DIR"
      N=${toString (builtins.length enabled)}
      [ "$N" -gt 0 ] || { echo "no enabled environments"; exit 0; }

      # --- even resource split, host headroom reserved first ----------------
      total_ram=$(( $(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
      avail_ram=$(( total_ram - ${toString cfg.hostReserve.ramMB} ))
      def_ram=$(( avail_ram / N )); [ "$def_ram" -lt 1024 ] && def_ram=1024
      total_cores=$(nproc)
      def_vcpu=$(( (total_cores - ${toString cfg.hostReserve.cores}) / N )); [ "$def_vcpu" -lt 1 ] && def_vcpu=1
      free_mb=$(df -Pm "$IMAGES_DIR" | awk 'NR==2{print $4}')
      def_disk=$(( (free_mb - 4096) / 1024 / N )); [ "$def_disk" -lt 10 ] && def_disk=10

      fetch_base() {
        os="$1"; url="$2"; sha="$3"; dest="$IMAGES_DIR/base-$os.qcow2"
        if [ ! -f "$dest" ]; then
          # Progress goes to stderr: stdout is captured as this function's result.
          echo "[*] fetching base image for $os" >&2
          curl -fL "$url" -o "$dest.part"
          if [ -n "$sha" ]; then
            echo "$sha  $dest.part" | sha256sum -c - || { rm -f "$dest.part"; echo "[x] sha256 mismatch for $os" >&2; exit 1; }
          fi
          mv "$dest.part" "$dest"
        fi
        printf '%s' "$dest"
      }

      provision_env() {
        name="$1"; os="$2"; net="$3"; userdata="$4"; metadata="$5"
        ram="$6"; vcpu="$7"; disk="$8"
        [ "$ram" = "-" ] && ram="$def_ram"
        [ "$vcpu" = "-" ] && vcpu="$def_vcpu"
        [ "$disk" = "-" ] && disk="$def_disk"

        case "$os" in
          ubuntu) base=$(fetch_base ubuntu "${cfg.baseImages.ubuntu.url}" "${cfg.baseImages.ubuntu.sha256}") ;;
          arch)   base=$(fetch_base arch   "${cfg.baseImages.arch.url}"   "${cfg.baseImages.arch.sha256}") ;;
          debian) base=$(fetch_base debian "${cfg.baseImages.debian.url}" "${cfg.baseImages.debian.sha256}") ;;
        esac

        vmdisk="$IMAGES_DIR/$name.qcow2"
        if [ ! -f "$vmdisk" ]; then
          qemu-img create -f qcow2 -F qcow2 -b "$base" "$vmdisk" >/dev/null
          qemu-img resize "$vmdisk" "''${disk}G" >/dev/null
        fi

        # cloud-init seed: inject the guest password (kept out of the Nix store)
        # into the user-data template, build the NoCloud ISO (volid MUST be cidata).
        seed="$IMAGES_DIR/$name-seed.iso"
        pw="$(cat ${gcfg.passwordFile})"
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
        umask 077
        sed "s|__GUEST_PASSWORD__|$pw|g" "$userdata" > "$tmp/user-data"
        cp "$metadata" "$tmp/meta-data"
        cloud-localds "$seed" "$tmp/user-data" "$tmp/meta-data"
        shred -u "$tmp/user-data" 2>/dev/null || true

        # domain XML: substitute the runtime values into the Nix template.
        sed \
          -e "s|@NAME@|$name|g" \
          -e "s|@RAM@|$ram|g" \
          -e "s|@VCPU@|$vcpu|g" \
          -e "s|@VMDISK@|$vmdisk|g" \
          -e "s|@SEED@|$seed|g" \
          -e "s|@NET@|$net|g" \
          ${domainTemplate} > "$tmp/domain.xml"

        virsh dominfo "$name" >/dev/null 2>&1 || virsh define "$tmp/domain.xml"
        virsh autostart "$name" >/dev/null 2>&1 || true
        virsh start "$name" 2>/dev/null || true
        echo "[+] $name: ram=''${ram}MiB vcpu=$vcpu disk=''${disk}G net=$net"
      }

      ${provisionCalls}
    '';
  };
in
{
  options.appliance = {
    guest.passwordFile = mkOption {
      # str, not path: a path type would copy the secret into the world-readable
      # Nix store. This is an absolute path resolved at runtime (sops-nix/agenix
      # or a first-boot generator).
      type = types.str;
      default = "/run/secrets/guest-password";
      description = "Absolute path (out-of-store) to the guest login password.";
    };

    images.dir = mkOption { type = types.str; default = "/var/lib/libvirt/images"; description = "Where VM disk images live."; };
    cache.dir = mkOption { type = types.str; default = "/var/cache/appliance"; description = "Where downloaded base images are cached."; };

    baseImages =
      let
        img = url: mkOption {
          type = types.submodule {
            options = {
              url = mkOption { type = types.str; default = url; description = "Base cloud image URL."; };
              sha256 = mkOption { type = types.str; default = ""; description = "Pinned SHA256 (empty = download without integrity check)."; };
            };
          };
          default = { };
        };
      in
      {
        ubuntu = img "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img";
        arch = img "https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2";
        debian = img "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2";
      };
  };

  config = mkIf cfg.enable {
    systemd.services.appliance-guests = {
      description = "Provision and start the per-environment guests";
      after = [ "appliance-libvirt-networks.service" "network-online.target" ];
      requires = [ "appliance-libvirt-networks.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${provisionGuests}/bin/appliance-provision-guests";
      };
    };
  };
}
