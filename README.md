# multilevel

[![shellcheck](https://github.com/sltcnb/multilevel-multiusage-desktop/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/sltcnb/multilevel-multiusage-desktop/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: POSIX/bash](https://img.shields.io/badge/shell-POSIX%20%7C%20bash-4EAA25?logo=gnubash&logoColor=white)](https://www.shellcheck.net/)
[![ANSSI PA-114](https://img.shields.io/badge/aligned-ANSSI--PA--114-002654)](https://cyber.gouv.fr/)

A locked-down laptop that runs three separate worlds side by side and lets you
flip between them with a single keystroke.

Under the hood it's a tiny Alpine Linux host whose only job is to run KVM virtual
machines and show them full-screen. You never touch the host directly — it boots
straight into the first VM, and `Super+1` / `Super+2` / `Super+3` swap between
them instantly on the same screen, keyboard and mouse. Each VM is a completely
separate environment (its own OS, its own network, its own disk), and the whole
point is that **they cannot talk to each other**. One can be compromised without
putting the others at risk.

It's built to line up with the French cybersecurity agency's guidance for
multi-environment workstations (ANSSI-PA-114). There's a section further down
that maps each recommendation to what the appliance actually does.

| Hotkey    | Environment      | Purpose                        | Default OS | Desktop |
|-----------|------------------|--------------------------------|------------|---------|
| `Super+1` | **office**       | Everyday work, email, browsing | Ubuntu     | GNOME   |
| `Super+2` | **development**  | Coding, dev tools              | Arch       | GNOME   |
| `Super+3` | **administration** | Sensitive/admin tasks        | Arch       | GNOME   |

The office VM runs Ubuntu because that's the only Linux that Microsoft's Intune /
Entra enrollment supports; the other two can be whatever you like.

## What it looks like

The bar across the top is the "trust bar": it's always visible and the highlighted
workspace number tells you which environment is currently active, so you can never
confuse one world for another. Below it, the active VM's desktop fills the screen,
and `Super+1/2/3` swaps which one is shown — instantly, on the same physical
display.

## How the isolation works

Every environment reaches the internet, but none can reach another — and that
holds even if one of the safeguards fails. Everything is enforced on the host,
so a guest has no say in it.

- **Separate layer-2 segments.** Each VM gets its own Linux bridge and its own
  `/24` subnet. Different bridges mean there's no shared broadcast domain, so one
  guest can't even ARP or flood a neighbour.
- **Routing between them is dropped.** Because the subnets differ, a cross-VM
  packet would have to be routed by the host. An nftables rule in the forward
  chain drops every ordered pair of environment subnets, both directions, for all
  pairs. A second redundant rule matches on the bridge names, so isolation
  survives even if subnets were renumbered.
- **libvirt's own per-network filtering** is a third independent layer. Knock any
  one layer out and the other two still hold the line.

Outbound internet is plain NAT (masquerade out whichever interface has the
default route). You can tighten any environment to a whitelist — DNS plus a fixed
list of IPs/CIDRs, everything else dropped — which is handy for the sensitive
`administration` VM. nftables matches IP addresses, not hostnames, so for
name-based rules you'd point the whitelist at a filtering proxy.

`environments/isolate.sh` builds all of this and then **verifies** it: from
inside each guest it pings every other subnet (must fail) and the internet (must
succeed), and it checks on the host that every drop rule is actually live.

## Getting it onto a machine

The workflow is: build an image on your Mac (or any Docker host), flash it to a
USB stick, boot the target machine from the stick once to install onto its
internal disk, then remove the stick.

### 1. Build the image

You need Docker running. The build runs inside a privileged container so it works
the same on an Apple-silicon Mac (it emulates x86-64) as on a Linux box.

```sh
git clone <your-repo-url> multilevel
cd multilevel
./build/make-image.sh
```

You get `out/appliance-alpine.qcow2` (~2 GB) after a few minutes.

### 2. Flash a USB stick

```sh
qemu-img convert -O raw out/appliance-alpine.qcow2 out/appliance.raw

diskutil list                       # find your USB, e.g. /dev/disk4 — be certain
diskutil unmountDisk /dev/diskN
sudo dd if=out/appliance.raw of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

Flashing wipes the whole stick — double-check the disk number. The `rdiskN` raw
node is much faster than `diskN`.

### 3. Set up firmware on the target

Before booting:

- Enable hardware virtualization (Intel VT-x / AMD SVM).
- Enable the IOMMU (Intel VT-d / AMD-Vi) — you'll want it if you later add GPU
  passthrough.
- Set the machine to boot from USB.
- Turn Secure Boot **off** for now (the image ships unsigned; you can turn it back
  on later with `host/secure-boot.sh`).

The image is built for UEFI, so pick the `UEFI: <your USB>` entry. If the machine
is legacy-BIOS only, rebuild with `BOOT_MODE=BIOS ./build/make-image.sh`.

### 4. Boot the stick — it installs itself

The stick notices it booted from removable media and runs the installer
automatically: it picks the largest internal disk, shows a 10-second abort
countdown, wipes the disk, installs the appliance, and powers off. No network and
no package downloads are needed for this step.

If you'd rather do it by hand, hit `Ctrl+Alt+F2` and run
`cd /opt/appliance && ./installer/install-to-disk.sh`.

### 5. Remove the stick and power on

Now it boots from the internal disk with the full drive available for VM storage.
The first boot runs the host setup automatically (hardware detection, the kiosk
user, hardening, the switching config, and Wi-Fi if configured), sizing the
per-VM RAM/CPU/disk split to the real machine.

### 6. Finish provisioning (as root, on tty2)

The desktop logs in as an unprivileged `kiosk` user with no sudo, so do admin
work as root on a separate console: `Ctrl+Alt+F2`, log in as `root` (change the
password immediately with `passwd`).

```sh
cd /opt/appliance
vi config.env        # set Wi-Fi, guest password, per-env options
```

If you're on Wi-Fi, set `WIFI_SSID` / `WIFI_PSK` / `WIFI_COUNTRY` and run
`./host/wifi.sh` (the passphrase is hashed, never stored in the clear). On wired
ethernet you can skip this.

If your Wi-Fi uses a captive portal with interactive Microsoft Entra / OAuth
login, press `Super+p` to open the portal in a browser, sign in once, and every
VM gets online through the host (they all share the host's single connection via
NAT). Do this **before** creating the VMs, because their first boot needs
internet.

Before the first run, it's recommended to pin the SHA256 of each base cloud
image you'll actually use (`UBUNTU_IMG_SHA256` / `ARCH_IMG_SHA256` /
`DEBIAN_IMG_SHA256` in `config.env` — see the comments there for where to get
the vendor's published checksum). Pinning is optional by default: an unset hash
downloads without an integrity check (with a warning), while a set hash is
strictly verified and a mismatch deletes the file and aborts. Set
`REQUIRE_IMG_SHA256=1` to make a missing pin a hard error.

Then build and lock down the VMs:

```sh
./environments/create.sh     # downloads cloud images, provisions each enabled VM
./environments/isolate.sh    # per-VM networks + firewall + the isolation checks
```

`isolate.sh` prints PASS/FAIL for every check — each VM must reach the internet
and must **not** reach either of the other two.

Reboot to confirm the full experience: you land on the office VM full-screen and
`Super+1/2/3` switches between them.

The one ordering rule that matters: **Wi-Fi → portal login → create → isolate.**
Guests need internet on first boot, which needs the portal cleared, which needs
the radio up.

## Day-to-day use

- `Super+1` / `Super+2` / `Super+3` — switch environments. This works even while a
  VM has grabbed the keyboard, because the hotkey is caught below the display
  server by `keyd`.
- `Super+p` — re-open the captive portal when the Wi-Fi session times out.
- `Super+y` — route a plugged YubiKey (or any USB device) to a chosen VM.
- `Super+Enter` — an unprivileged shell (kiosk user).

Everything else is automatic: autologin, VM autostart, and the firewall all
persist across reboots.

### Routing a YubiKey to one VM

When you plug in a YubiKey, a small chooser pops up on screen asking which
environment should get it. The key is then USB-passed-through to **only** that VM
and detached from any other — it's never shared across environments. A udev rule
triggers the chooser on insert, and `Super+y` re-runs it manually. usbguard is
told to admit YubiKeys specifically so they aren't blocked by the default USB
lockdown. See `host/usb-to-vm.sh`.

## Configuration

Everything is driven by `config.env` on the appliance (`/opt/appliance/config.env`).
The committed `config.env.example` is the template — copy it and edit. The real
`config.env` is deliberately **not** in git because it holds secrets.

```sh
ENVS="office development administration"    # ordered; position fixes workspace + subnet

office_ENABLED=1;         office_OS="ubuntu"; office_DE="gnome"
development_ENABLED=1;    development_OS="arch";   development_DE="gnome"
administration_ENABLED=1; administration_OS="arch"; administration_DE="gnome"
```

- **Add or remove environments** — `ENVS` is just an ordered list. You can define
  as many as you like; each one's position fixes its workspace number and subnet,
  so enabling or disabling one never renumbers the others. Disable with
  `<env>_ENABLED=0`.
- **OS** — `ubuntu`, `arch`, or `debian` (all provisioned identically via
  cloud-init). The office VM must stay Ubuntu for Entra/Intune.
- **Desktop** — `<env>_DE` accepts `gnome`, `xfce4`, `kde`, `mate`, `lxqt`, or
  `none` for a CLI-only guest.
- **Egress** — `<env>_EGRESS_MODE=all|whitelist` plus `<env>_EGRESS_ALLOW="ip ip"`.
- **VPN** — `<env>_VPN=1` with WireGuard details, then run `environments/vpn.sh`.
- **Custom APT source** — point apt-family guests (ubuntu/debian) at your own
  package source instead of the public archives: `APT_MIRROR` sets a base mirror
  (via cloud-init `apt.primary`) and `APT_PROXY` sets a caching proxy such as
  apt-cacher-ng (applied as the global apt proxy, so it also covers the in-guest
  Microsoft/Wazuh repos). Both empty = default upstream mirrors; Arch guests
  ignore them. Rerouting where bytes come from doesn't loosen trust — the pinned
  GPG fingerprints still gate what is installed.

RAM, vCPUs and disk are split evenly across the enabled environments, with host
headroom reserved first.

### Secrets

Any of these can be set to `"generate"` (or left empty) and the scripts will
create a strong random value, use it, and record it in
`/root/generated-secrets.txt`: `HOST_ROOT_PASSWORD`, `GUEST_PASSWORD`,
`LUKS_PASS`, and each `<env>_DISK_PASS`. Once everything is set up,
`environments/scrub-secrets.sh` blanks them back out of `config.env`.

Don't bake secrets into a shipped image — set them on the appliance instead.

## Enterprise integrations

- **office → Intune / Entra.** With `office_INTUNE=1` the office VM is prepared for
  Microsoft Intune enrollment (Ubuntu-only, which is why office is Ubuntu). The
  actual enrollment is interactive after first boot.
- **office → Outlook + Teams.** With `office_MSAPPS=1` these are installed as Edge
  progressive web apps. Microsoft discontinued the native Linux Teams client and
  the community wrapper gets blocked by Conditional Access, so the Edge PWAs are
  the path that actually works with managed sign-in.
- **development / administration → Wazuh.** Set `<env>_WAZUH=1` and `WAZUH_MANAGER`
  and those VMs auto-enroll the Wazuh agent for monitoring (apt on Ubuntu/Debian,
  AUR on Arch).

## Users and privileges

- **`kiosk`** — the autologin desktop user. Unprivileged: it can view and launch
  the VMs (member of `libvirt`/`kvm`) but has no sudo and no root powers. This is
  what you use day to day. A compromise here can't reach the host.
- **`root`** — administration only, on tty2 (`Ctrl+Alt+F2`). All the provisioning
  scripts need it. There's deliberately no sudo on the host, keeping the trusted
  computing base small.

## Repository layout

```
config.env.example        template for config.env (secrets live only in config.env, git-ignored)
lib/common.sh             shared helpers: logging, guards, config, the environment model
build/make-image.sh       build the bootable Alpine image (runs in Docker)
installer/install-to-disk.sh  clone the image onto the internal disk, optional LUKS
host/
  detect-and-install.sh   detect CPU/RAM/disk, install packages, nested virt, resource split
  configure.sh            kiosk user, autologin, auto-startx, usbguard default-deny
  harden.sh               kernel sysctl hardening + optional host firewall
  switching.sh            i3 config per environment, keyd hotkeys, the trust bar
  wifi.sh                 optional Wi-Fi uplink (hashed passphrase, stable MAC)
  captive-portal.sh       optional Entra/OAuth captive-portal helper (Super+p)
  usb-allow.sh            whitelist a USB device past the default-deny policy
  usb-to-vm.sh            route a YubiKey/USB device to a chosen VM (Super+y / auto on plug)
  secure-boot.sh          optional Secure Boot + TPM PCR binding (experimental)
  tpm-initramfs-hook.sh   optional hands-free TPM unlock of the encrypted root
environments/
  create.sh               build each enabled VM, install its desktop, optional per-VM LUKS
  isolate.sh              per-VM networks + all-pairs firewall drop + verification
  vpn.sh                  optional per-VM non-bypassable WireGuard tunnel
  scrub-secrets.sh        wipe secrets from config.env after setup
```

Every script is `set -euo pipefail`, checks for root and its dependencies, and is
safe to re-run.

## How the automated install of guests works

Ubuntu, Arch and Debian all publish official **cloud images** — qcow2 files that
already contain cloud-init. The appliance boots one of these, hands it a small
NoCloud seed ISO with the user and package configuration, and cloud-init
provisions the guest unattended on first boot. Every guest OS goes through the
exact same path, which keeps provisioning uniform and reliable. (Arch has no
official unattended installer otherwise; scripting `pacstrap` from the ISO is
possible but brittle, so the cloud image is the better choice there too.)

## Per-environment VPN

`environments/vpn.sh` can give an environment its own encrypted tunnel that the
guest cannot turn off or bypass, because it's all enforced on the host:

1. A WireGuard interface is created on the host from the environment's config.
2. Policy routing sends that environment's traffic into the tunnel rather than out
   the normal uplink.
3. An nftables egress-lock drops any attempt to leave via the normal WAN and only
   allows the WireGuard interface. If the tunnel is down, that environment simply
   has no internet (fail-closed).

The VM just sees a normal NIC with internet; it has no way to know or change that
its traffic is forced through a specific tunnel. This is opt-in and needs a real
WireGuard peer.

## Alignment with ANSSI-PA-114

The appliance targets ANSSI's guidance for securing a multi-environment
workstation. Status: **Built-in** = enforced by default, **Opt-in** = supported
but you enable it (sometimes with a firmware/hardware setting).

| Requirement | Status | How it's met |
|-------------|--------|--------------|
| One environment per VM (preferred over sandboxes) | Built-in | each environment is its own KVM VM |
| Hardened host, minimal trusted base | Built-in | minimal Alpine, no user apps; `host/harden.sh` sysctl hardening + optional host firewall |
| Desktop runs unprivileged | Built-in | autologin an unprivileged `kiosk` user; root reserved for tty2 |
| Always know the active environment | Built-in | the always-visible, color-coded trust bar |
| Network isolation, no impersonation between environments | Built-in | separate bridge + subnet per env, nftables all-pairs drop |
| Per-environment outbound control | Built-in | `<env>_EGRESS_MODE=whitelist` |
| Peripheral compartmentalization (USB) | Built-in | usbguard default-deny; whitelist with `host/usb-allow.sh`; YubiKey routed to one VM |
| No secrets left at rest | Built-in | `environments/scrub-secrets.sh` blanks passwords/keys after setup |
| Memory encryption (anti cold-boot) | Opt-in | `mem_encrypt=on` set; full DRAM encryption needs TSME enabled in firmware |
| Disk encryption | Opt-in | LUKS2 via `ENCRYPT=1`; key auto-generated if none supplied |
| Per-environment user-keyed encryption | Opt-in | per-VM LUKS via `<env>_ENCRYPT_DISK=1` + `<env>_DISK_PASS` |
| Dedicated non-bypassable VPN per environment | Opt-in | host-enforced WireGuard via `<env>_VPN=1` + `environments/vpn.sh` |
| Secure/measured boot + TPM | Opt-in | `host/secure-boot.sh` (Secure Boot + TPM PCR bind) + `host/tpm-initramfs-hook.sh` |

The opt-in items are left off by default for good reason: some depend on a
firmware toggle the OS can't set (memory encryption needs TSME in the BIOS), and
some are powerful but brick-prone enough that they should be tested on a spare
machine first (Secure Boot key enrollment, TPM-bound unlock, full-disk
encryption).

## Development

Every script is `set -euo pipefail` (or `set -eu` for the POSIX `lib/common.sh`),
checks for root and its dependencies, and is safe to re-run. Continuous
integration runs [ShellCheck](https://www.shellcheck.net/) on every push and pull
request; it fails on warnings and above. Run the same check locally before
opening a PR:

```sh
shellcheck -x -S warning lib/*.sh host/*.sh environments/*.sh installer/*.sh build/*.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for style and review expectations.

## Security

Isolation between environments is the core guarantee of this project. To report a
vulnerability privately, see [SECURITY.md](SECURITY.md). Secrets live only in the
git-ignored `config.env` or on the appliance — never in the repository or a
shipped image.

Supply-chain integrity is enforced fail-closed: `environments/create.sh` refuses
to use a base cloud image whose SHA256 isn't pinned in `config.env` and matching,
and refuses to trust a third-party apt signing key (Microsoft, Wazuh) whose
fingerprint doesn't match the pinned value after import. `host/harden.sh` always
sets `PermitEmptyPasswords no` and denies the passwordless kiosk console account
over SSH, regardless of the `HARDEN_INPUT`/`HOST_SSH` firewall settings.

## License

Released under the [MIT License](LICENSE).
