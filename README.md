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
| `Super+1` | **office**       | Everyday work, email, browsing | Windows 11 | native  |
| `Super+2` | **development**  | Coding, dev tools              | Arch       | GNOME   |
| `Super+3` | **administration** | Sensitive/admin tasks        | Arch       | GNOME   |

The office VM defaults to **Windows 11** so it gets first-class Entra ID join,
Intune MDM and native Microsoft 365 / Teams / Outlook. Windows needs an install
ISO you supply (`WINDOWS_ISO`) and installs unattended on a q35 + UEFI + vTPM
profile — see "Configuration" and "How the automated install of guests works".
Prefer a lighter, no-license Linux office? Set `office_OS="ubuntu"`
(`office_DE="gnome"`); Intune there is the limited `intune-portal` client. The
other two environments can be any supported OS.

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

`src/environments.sh isolate` builds all of this and then **verifies** it: from
inside each guest it pings every other subnet (must fail) and the internet (must
succeed), and it checks on the host that every drop rule is actually live. A
failed check is a failed run — the script exits non-zero, so a breach can't slip
by as a warning in a boot log. Checks that couldn't run yet (guest still
booting, agent not up) are reported as skipped and don't fail the run, but the
script tells you isolation is not fully verified until you re-run it.

## Continuous assurance: the isolation watch

`isolate.sh` proves isolation once, at setup — after that, nothing used to look
again. A ruleset can be flushed, a libvirt network redefined, a script half
re-run, and the machine keeps presenting three environments that no longer have
a fence between them. `src/host.sh isolation-watch` is the recurring check: every
minute (busybox crond on the appliance, a systemd timer elsewhere) it asserts
that every inter-environment DROP rule is still live in the kernel, and
publishes the verdict to `/run/appliance/isolation.status` — one TAB-separated
line, `STATE EPOCH DETAIL`, with STATE one of `OK`, `FAIL`, `UNKNOWN`.

The contract is deliberately pessimistic. The file lives on a tmpfs, so it is
gone after a reboot: the answer is UNKNOWN until the first check of the new
boot, never a stale OK inherited from the previous one. A missing or unparsable
file also means UNKNOWN, and readers must never crash on it. Anything that wants
to show "is it still isolated?" reads this file — the trust bar lights up when
the verdict is FAIL or UNKNOWN (it stays quiet while everything is OK). Running
it by hand
(`src/host.sh isolation-watch --once`) exits 0/1/2 for OK/FAIL/UNKNOWN.

The watch is installed automatically by `src/environments.sh isolate`.
`ISOLATION_WATCH=0` disables it; `ISOLATION_WATCH_INTERVAL` sets the period in
seconds (cron rounds sub-minute values up to a whole minute). Only state
**transitions** are written to the audit log, so the one line that matters —
isolation breaking, or coming back — isn't buried under a day of identical OKs.

## Audit trail

Security-relevant events are recorded in an append-only log,
`/var/log/appliance-audit.log` (mode 0600, root-only; it rotates at 256 KiB,
keeping one `.1` generation). One line per event:

```
2026-07-29T10:55:30Z isolation-check state=FAIL prev=OK pairs=4/6 missing=office->development
```

Recorded today: isolation-check state transitions (the watch), captive-portal
logins, USB-to-VM routing decisions, update checks/applications/rollbacks, and
file-diode transfers (every accepted or refused inter-domain file, with its
hash and direction — see below). Two properties matter more than the list:

- **It never blocks the action it records.** If the log can't be written, the
  portal login, USB routing or update still happens — auditing is a witness,
  not a gate.
- **The kiosk user can report events without being able to read the log.**
  Unprivileged events (portal login, the USB chooser) go through a mode-1733
  spool directory and are folded into the real log by the next root-run event.

Read it as root with `tail -f /var/log/appliance-audit.log`, or with
`audit_tail` from `src/lib.sh`.

## Inter-domain file diodes (ANSSI-PA-114 §3.18)

The default is **no exchange at all** between environments — that is the whole
point of the isolation above, and it is exactly what PA-114 requires ("*Les
communications entre domaines utilisateurs sont proscrites*"). PA-114 §3.18 then
allows **one** narrow, optional exception when file exchange is genuinely needed
and authorized: a **diode** — a *unidirectional, mediated, logged* transfer of
**files** between two named domains. `src/environments.sh diode` implements that
and only that. It is **off** unless you set `DIODES`.

A diode here is **not** a one-way firewall rule. §3.18 forbids using it to create
"*un canal de communication non surveillé d'un domaine utilisateur à un autre*",
and a one-way IP allow is precisely that (a stateful TCP allow isn't even one-way
at the data layer). So the diode never touches the guest network: the isolation
ruleset stays a total all-pairs DROP, and the only thing that ever bridges two
domains is the **host**, moving bytes it has read and you have accepted, over
each guest's qemu-guest-agent channel. The two domains have no path to each other
at any layer.

How a transfer works, and how it maps to §3.18:

1. **Queue it in the source (§3.18.3).** In the sending VM, drop the file into
   `~/diode-out/<destination-env>/`. Nothing leaves that you did not put there.
2. **Run the diode (§3.18.2).** `./setup.sh 11` (or
   `src/environments.sh diode`). Only the `SRC>DST` pairs in `DIODES` flow, in
   that direction; an unlisted or reversed pair is refused.
3. **Accept it on the host (§3.18.4).** For each file the host shows the name,
   size and sha256 and asks you to confirm. The prompt runs on the socle — a
   support surface outside every user domain. (`--yes` skips it for automation;
   `--list` shows what is pending without moving anything.)
4. **It is vetted, optionally (§3.18.6).** With `DIODE_SCAN=1` the host copy is
   run past a pattern deny-list and clamav (if installed) before delivery; a hit
   refuses the file.
5. **It is logged (§3.18.5).** Every transfer *and every refusal* is written to
   the audit log with the file name, sha256, byte count, direction and reason.
6. **It arrives in the destination.** The file lands in
   `~/diode-in/<source-env>/` in the receiving VM; the source copy is cleared.

Configure it in `config.env` — for example, to allow pushing files *down* from
the sensitive admin domain and from dev to office:

```sh
DIODES="administration>development administration>office development>office"
DIODE_MAX_BYTES=8388608     # per-file ceiling (8 MiB)
DIODE_SCAN=1                # optional §3.18.6 content vetting
DIODE_SCAN_DENYLIST="CONFIDENTIEL SECRET"
```

Filenames are validated to a safe character set (a name from a possibly-hostile
domain is never interpolated raw into a guest command), oversize files are
refused, and a name collision in the destination is delivered under a
timestamped name rather than overwriting. §3.18.7's stricter "dedicated,
unprivileged support domain per diode" for the scanning step is a further
hardening step (route `DIODE_SCAN` to a dedicated analysis VM); the built-in
scan runs on the host.

## Getting it onto a machine

The workflow is: build an image on your Mac (or any Docker host), flash it to a
USB stick, boot the target machine from the stick once to install onto its
internal disk, then remove the stick.

The whole build-host workflow is exactly three endpoints, in order — one to
configure, one to build-and-flash, one to run on the appliance:

```sh
./configure.sh   # 1. write config.env
./flash.sh       # 2. build the image, flash a USB stick
./setup.sh       # 3. on the appliance: create + isolate the VMs
```

### 1. Configure

```sh
git clone <your-repo-url> multilevel
cd multilevel
./configure.sh
```

`configure.sh` is the entry point: an interactive wizard that runs on the build
machine (macOS or Linux, no dependencies) and walks you through the environments,
the credentials, Wi-Fi, the security toggles, the supply-chain pinning and the
build options. It writes `config.env` (mode 0600; an existing one is backed up
first) — and **nothing else**. It does not build or flash; that is `flash.sh`'s
job. `./configure.sh --defaults` writes a default `config.env` non-interactively.
You can equally copy `config.env.example` by hand instead of running the wizard.

The shipped image keeps root **locked**; the installed system sets root at first
boot from `HOST_ROOT_PASSWORD` (required — secrets are never auto-generated).

### 2. Build and flash a USB stick

You need Docker running. The build runs inside a privileged container so it works
the same on an Apple-silicon Mac (it emulates x86-64) as on a Linux box.

```sh
./flash.sh
```

`flash.sh` does the whole second half in one go: it builds the image (reading the
build options you chose in `config.env`), converts the qcow2 to raw, lists the
external/removable disks, and flashes the one you pick — after you confirm the
target by typing its device name a second time. It reuses an existing qcow2 if one
is fresh (`--build` forces a rebuild); the system disk is refused outright, and
`--image-only` stops before the flash step. You get `out/appliance-alpine.qcow2`
(~2 GB) after a few minutes on the first run.

If a local `config.env` exists, it is **baked into the image** so the appliance
boots with your Wi-Fi / per-env / password settings already in place — no editing
on the box, and the installer preserves it (hardware-detected values are still
re-detected on the real machine at first boot). Because `config.env` holds secrets
(Wi-Fi PSK, passwords), **the resulting image is sensitive — don't distribute it**.
Skip baking with `BAKE_CONFIG=0` (the appliance then starts from
`config.env.example` and you edit it on tty2).

You can also build by hand with `./src/build.sh` and flash it yourself:

The manual equivalent (what the script runs under the hood):

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
  on later with `src/host.sh secure-boot`).

The image is built for UEFI, so pick the `UEFI: <your USB>` entry. If the machine
is legacy-BIOS only, rebuild with `BOOT_MODE=BIOS ./src/build.sh`.

### 4. Boot the stick — it installs itself

The stick notices it booted from removable media and runs the installer
automatically: it picks the largest internal disk, shows a 10-second abort
countdown, wipes the disk, installs the appliance, and powers off. No network and
no package downloads are needed for this step.

If you'd rather do it by hand, hit `Ctrl+Alt+F2` and run
`cd /opt/appliance && ./src/host.sh install-to-disk`.

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
./setup.sh           # the numbered menu of the remaining steps
```

The host base — hardware detection, kiosk user, hardening, i3 switching, Wi-Fi
and the captive-portal hook — already ran automatically at first boot, so
`setup.sh` only offers what is left: **1) create the VMs** and **2)
isolate + verify**, plus the day-two operations (guest passwords, VPN, scrubbing
secrets, secure boot). `./setup.sh <n>` runs step n directly; each step
is also runnable as its own script.

If you're on Wi-Fi, set `WIFI_SSID` / `WIFI_PSK` / `WIFI_COUNTRY` and run
`./src/host.sh wifi` (the passphrase is hashed, never stored in the clear). On wired
ethernet you can skip this.

If your Wi-Fi uses a captive portal with interactive Microsoft Entra / OAuth
login, press `Super+p` to open the portal in a browser, sign in once, and every
VM gets online through the host (they all share the host's single connection via
NAT). Do this **before** creating the VMs, because their first boot needs
internet.

Before the first run, it's recommended to pin each base cloud image you'll
actually use, one of two ways (`config.env.example` explains both in detail):
pin the vendor's own signature (`UBUNTU_IMG_GPG_FPR` / `ARCH_IMG_GPG_FPR` /
`DEBIAN_IMG_GPG_FPR`, verified automatically on every run), or pin a SHA256 by
hand (`*_IMG_SHA256` — this wins when both are set). Pair a hand-pinned hash
with `*_IMG_DATE` (the vendor's dated, immutable directory) or it goes stale on
the next vendor rebuild. Pinning is optional by default: with neither set, the
image downloads without an integrity check (with a warning). Set
`REQUIRE_IMG_SHA256=1` to make a missing pin a hard error.

Then build and lock down the VMs:

```sh
./src/environments.sh create     # downloads cloud images, provisions each enabled VM
./src/environments.sh isolate    # per-VM networks + firewall + the isolation checks
```

`isolate.sh` prints PASS/FAIL for every check — each VM must reach the internet
and must **not** reach either of the other two.

Each VM's first boot installs its full desktop environment over the network
(GNOME on the Ubuntu office VM, etc.), which takes several minutes and ends in
one automatic reboot into the desktop — so the first boot is slow by design.
Watch it with `virsh console <env>` (then in-guest `tail -f /var/log/de-install.log`).

To change a guest's password later without rebuilding, use
`./src/environments.sh set-guest-password <env>` (live, via the guest agent).

Reboot to confirm the full experience: you land on the office VM full-screen and
`Super+1/2/3` switches between them. `Super+Return` opens a terminal and
`Super+p` the captive portal — both work even while a VM holds the keyboard.

The one ordering rule that matters: **Wi-Fi → portal login → create → isolate.**
Guests need internet on first boot, which needs the portal cleared, which needs
the radio up.

## Day-to-day use

- `Super+1` / `Super+2` / `Super+3` — switch environments. This works even while a
  VM has grabbed the keyboard, because the hotkey is caught below the display
  server by `keyd`.
- `Super+p` — re-open the captive portal when the Wi-Fi session times out.
- `Super+y` — route a plugged YubiKey (or any USB device) to a chosen VM.
- `Super+w` — add a new Wi-Fi network (e.g. working from home). The kiosk user
  does this itself with no root: it's in the `netdev` control group, so the
  helper drives `wpa_cli` against wpa_supplicant, and the network is saved and
  reconnects on the next boot. (Wi-Fi hardware must be present and wpa_supplicant
  running — i.e. `host.sh wifi` has run at least once.)
- `Super+Enter` — an unprivileged shell (kiosk user).

Everything else is automatic: autologin, VM autostart, and the firewall all
persist across reboots.

### Routing a YubiKey to one VM

When you plug in a YubiKey, a small chooser pops up on screen asking which
environment should get it. The key is then USB-passed-through to **only** that VM
and detached from any other — it's never shared across environments. A udev rule
triggers the chooser on insert, and `Super+y` re-runs it manually. usbguard is
told to admit YubiKeys specifically so they aren't blocked by the default USB
lockdown. See `src/host.sh usb-to-vm`.

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
  cloud-init), or `windows` for a Windows 11 environment. Windows takes a
  separate path (unattended ISO install on q35 + UEFI + vTPM; no cloud-init) and
  needs `WINDOWS_ISO` set to a Windows 11 install ISO you supply — the repo
  cannot download or license Windows. It also wants more resources
  (`<env>_VCPU>=2`, `RAM_MB>=4096`, `DISK_GB>=64`). `virtio-win` and the SPICE
  guest tools are fetched automatically. The ISO is too big for the image's
  script-baking mechanism, so by default you copy it to `WINDOWS_ISO` on the box
  yourself; set `WINDOWS_ISO_SRC` (its path on the build host) to have `flash.sh`
  bake it into the image instead — that needs a larger `IMG_SIZE` (OS + ISO),
  `BAKE_CONFIG=1`, and a USB stick at least `IMG_SIZE`.
- **Hostname** — `<env>_HOSTNAME` sets the guest's OS hostname (default = the env
  name); it also becomes the NetBird peer name and the default Wazuh agent name,
  so one knob names the machine everywhere.
- **Desktop** — `<env>_DE` accepts `gnome`, `xfce4`, `kde`, `mate`, `lxqt`, or
  `none` for a CLI-only guest.
- **Egress** — `<env>_EGRESS_MODE=all|whitelist` plus `<env>_EGRESS_ALLOW="ip ip"`.
- **VPN** — `<env>_VPN=1` with WireGuard details, then run `src/environments.sh vpn`.
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

Every secret must be an explicit value you chose, written in `config.env` (by
`configure.sh` or by hand): `HOST_ROOT_PASSWORD`, `GUEST_PASSWORD`,
`LUKS_PASS`, and each `<env>_DISK_PASS`. Secrets are **never auto-generated** —
a password you did not choose is a password you cannot know, and a generated
root or LUKS password locks you out of your own machine. An empty secret is a
hard error at provisioning, not a random value. Once everything is set up,
`src/environments.sh scrub-secrets` blanks them back out of `config.env`.

Don't bake secrets into a shipped image — set them on the appliance instead.

## Enterprise integrations

- **office → Intune / Entra.** With `office_INTUNE=1` the office VM is an
  Entra/Intune device. On **Windows 11 (the default)** this is native, full MDM:
  Entra ID join, device-compliance evaluation and Conditional Access, performed
  interactively / by policy after first boot. On an Ubuntu office VM it is the
  limited `intune-portal` client instead.
- **office → Outlook + Teams / M365.** On Windows, install native Microsoft 365 /
  Teams / Outlook via Intune or the Company Portal after enrollment. On an Ubuntu
  office VM, `office_MSAPPS=1` installs them as Edge progressive web apps
  (Microsoft dropped the native Linux Teams client and the community wrapper gets
  blocked by Conditional Access, so the managed-Edge PWAs are the path that works).
- **development / administration → Wazuh.** Set `<env>_WAZUH=1` and `WAZUH_MANAGER`
  and those VMs auto-enroll the Wazuh agent for monitoring (apt on Ubuntu/Debian,
  AUR on Arch). `WAZUH_AGENT_GROUP` sets the agent group and `<env>_WAZUH_NAME`
  the registered name per environment (default = the guest hostname) — apt passes
  them as Wazuh's install env vars, Arch writes them into `ossec.conf`.
- **development / administration → NetBird.** Set `<env>_NETBIRD=1` and
  `NETBIRD_SETUP_KEY` (and `NETBIRD_MANAGEMENT_URL` for a self-hosted control
  plane) and those VMs install the NetBird agent and join your mesh VPN on first
  boot — apt via NetBird's signed repo (pin its key in `NETBIRD_GPG_FPR`, which
  ships empty and fails closed until you set it), Arch via the AUR. NetBird runs
  *inside* the guest over that domain's own uplink, so it never bridges the
  isolated local VMs; the host's all-pairs drop is untouched. On a
  whitelisted-egress domain (the default for `administration`) you must add
  NetBird's endpoints to `<env>_EGRESS_ALLOW` or `netbird up` can't reach them.

## Users and privileges

- **`kiosk`** — the autologin desktop user. Unprivileged: it can view and launch
  the VMs (member of `libvirt`/`kvm`) but has no sudo and no root powers. This is
  what you use day to day. A compromise here can't reach the host.
- **`root`** — administration only, on tty2 (`Ctrl+Alt+F2`). All the provisioning
  scripts need it. There's deliberately no sudo on the host, keeping the trusted
  computing base small.

## Repository layout

Three endpoints at the root, one per stage, and four files under `src/`:

```
configure.sh              step 1: interactive wizard, writes config.env (only)
flash.sh                  step 2: build the image + flash it to a USB stick (safe disk picker)
setup.sh                  step 3: on the appliance, menu of the remaining steps (create VMs, isolate, day-two ops)
config.env.example        template for config.env (secrets live only in config.env, git-ignored)

src/lib.sh                shared library, sourced by everything: logging, guards, config, the
                          environment model, the audit log, guest-disk mount (qemu-nbd), the
                          guest desktop installer, and the Windows autounattend.xml generator
src/build.sh              build the bootable Alpine image (runs in Docker)
src/host.sh <command>     all host-side operations:
    detect-and-install    detect CPU/RAM/disk, install packages, nested virt, resource split
    configure             kiosk user, autologin, auto-startx, usbguard default-deny
    harden                kernel sysctl hardening + optional host firewall
    switching             i3 config per environment, keyd hotkeys, the trust bar
    wifi                  optional Wi-Fi uplink (hashed passphrase, stable MAC)
    captive-portal        optional Entra/OAuth captive-portal helper (Super+p)
    install-to-disk       clone the image onto the internal disk, optional LUKS
    isolation-watch       recurring check that the isolation rules are still live + status file
    usb-allow             whitelist a USB device past the default-deny policy
    usb-to-vm             route a YubiKey/USB device to a chosen VM (Super+y / auto on plug)
    secure-boot           optional Secure Boot + TPM PCR binding (experimental)
    tpm-initramfs-hook    optional hands-free TPM unlock of the encrypted root
    compliance-check      post-install conformity gate
    update                signed in-place update of the appliance tree (--check/--rollback)
    update-packages       upgrade host + guests, write an SBOM
    secure-erase          secure erasure / end-of-life decommission
src/environments.sh <command>   all per-environment (guest VM) operations:
    create                build each enabled VM, install its desktop, optional per-VM LUKS
    isolate               per-VM networks + all-pairs firewall drop + verification
    vpn                   optional per-VM non-bypassable WireGuard tunnel
    set-guest-password    change a running guest's password via the guest agent
    guest-doctor          inspect/repair a shut-off guest from the host — no password, no guest agent
    scrub-secrets         wipe secrets from config.env after setup
    diode                 PA-114 §3.18 inter-domain file diode (off unless DIODES is set)
```

`src/host.sh` and `src/environments.sh` are dispatchers: run a command with
`src/host.sh <command> [args]`. `setup.sh` is just a friendly numbered menu over
the common ones. Every script is `set -eu` (`set -euo pipefail` under bash),
checks for root and its dependencies, and is safe to re-run.

## How the automated install of guests works

Ubuntu, Arch and Debian all publish official **cloud images** — qcow2 files that
already contain cloud-init. The appliance boots one of these, hands it a small
NoCloud seed ISO with the user and package configuration, and cloud-init
provisions the guest unattended on first boot. Every guest OS goes through the
exact same path, which keeps provisioning uniform and reliable. (Arch has no
official unattended installer otherwise; scripting `pacstrap` from the ISO is
possible but brittle, so the cloud image is the better choice there too.)

The guest's login does **not** depend on that going well. `create.sh` writes the
password hash into the new disk before the VM has ever booted, in addition to
handing it to cloud-init. This is deliberate redundancy: everything else the
seed carries — the account, the desktop, the guest agent — only happens if
cloud-init runs, so a datasource it declines to read used to lock the operator
out of all three environments at once, with no way in and no way to find out
why.

**Windows is a separate path.** There is no Windows cloud image and no cloud-init,
so a `windows` environment installs from the ISO you supply (`WINDOWS_ISO`),
driven by an `autounattend.xml` the appliance generates
(`src/lib.sh`) and hands to Windows Setup on a tiny CD. It runs
on the profile Windows 11 requires — **q35 + UEFI + a software TPM (swtpm) +
Secure Boot capability** — which is a different machine/firmware than the SeaBIOS
Linux guests use. For a hands-off first install the target disk is presented as
SATA and the NIC as `e1000e` (both have inbox Windows drivers, so Setup needs no
driver injection), and `virtio-win` (drivers + `qemu-guest-agent`) plus the SPICE
guest tools install on first logon. The first boot runs Setup unattended
(~20–40 min); if the very first boot shows "Press any key to boot from CD", press
one key (only the first boot can reach that prompt). None of the Linux offline
resilience (password/network pre-seed, `guest-doctor`) applies to a Windows guest.

## When a guest goes wrong

`src/environments.sh guest-doctor` is the tool for "I can't log in" and "there's
no desktop". It goes in through the **host**: `qemu-nbd` attaches the guest's
qcow2 and the guest's filesystem becomes ordinary files. It therefore needs no
password, no SSH and no qemu-guest-agent — which matters, because the agent is
itself installed by cloud-init, so the failure that hurts most also takes out
every other repair path. `set-guest-password.sh` remains the quick route for a
*healthy, running* guest; this is the one for a broken one.

The VM must be shut off (`virsh shutdown <env>`) — mounting a disk a live qemu
also has open corrupts it, so every mode refuses to run against a running
domain.

```sh
./src/environments.sh guest-doctor                 # report on every environment
./src/environments.sh guest-doctor --password office    # reset the login, offline
./src/environments.sh guest-doctor --install-de office  # arm the desktop install
```

The report answers the questions you cannot answer from a console login prompt:

| Line | What it means |
|------|---------------|
| `cloud-init seed: NOT ATTACHED` | the guest never had a seed to read — nothing in it applied |
| `cloud-init ran as: NEVER RAN` | cloud-init never started; the account and desktop were never created |
| `datasource: none recorded` | cloud-init ran but did not consume our seed |
| `user 'operator': LOCKED` | the account exists with no usable password — indistinguishable from "wrong password" at a console |
| `desktop install: ABORTED — guest disk too small` | apt ran out of room; raise `<env>_DISK_GB` and `RECREATE=<env>` |
| `desktop install: never armed` | the installer never reached the image (cloud-init did not run) |

## Per-environment VPN

`src/environments.sh vpn` can give an environment its own encrypted tunnel that the
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

## Updating a deployed appliance

Without an updater, shipping a fix to a machine in the field means rebuilding
the image, reflashing a stick, wiping the internal disk and losing every VM —
which in practice means the fix never lands. `src/host.sh update` replaces the
`/opt/appliance` code tree in place and nothing else: `config.env`, the
installer/first-boot markers, VM storage and the libvirt domain definitions are
machine state and are carried across untouched. The new tree is downloaded,
signature-verified and syntax-checked, then swapped in atomically (a rename —
never a partial copy over the live tree), and previous trees are kept so a bad
update can be undone:

```sh
./src/host.sh update --check      # report what is available; change nothing
./src/host.sh update              # fetch, verify, swap in, re-run the host scripts
./src/host.sh update --rollback   # restore the previous tree
```

Signatures are mandatory because the alternative is "download and run as root":
with `UPDATE_GPG_FPR` empty the update is refused outright (fail closed).
`UPDATE_INSECURE=1` exists as an escape hatch and is not a supported
configuration. Two channels: a tarball at `UPDATE_URL` with a detached
`UPDATE_URL.sig`, or `UPDATE_CHANNEL=git` moving to a signed tag/commit from
`UPDATE_GIT_REMOTE` / `UPDATE_GIT_REF`. `UPDATE_KEEP_BACKUPS` (default 3)
previous trees are kept for rollback, `UPDATE_REQUIRE_VMS_OFF=1` refuses to run
while any VM is up, and every check/apply/rollback lands in the audit log.

## Alignment with ANSSI-PA-114

The appliance targets ANSSI's guidance for securing a multi-environment
workstation. Status: **Built-in** = enforced by default, **Opt-in** = supported
but you enable it (sometimes with a firmware/hardware setting).

| Requirement | Status | How it's met |
|-------------|--------|--------------|
| One environment per VM (preferred over sandboxes) | Built-in | each environment is its own KVM VM |
| Hardened host, minimal trusted base | Built-in | minimal Alpine, no user apps; `src/host.sh harden` sysctl hardening + optional host firewall |
| Desktop runs unprivileged | Built-in | autologin an unprivileged `kiosk` user; root reserved for tty2 |
| Always know the active environment | Built-in | the always-visible, color-coded trust bar |
| Network isolation, no impersonation between environments | Built-in | separate bridge + subnet per env, nftables all-pairs drop, continuously re-verified by `src/host.sh isolation-watch` |
| Per-environment outbound control | Built-in | `<env>_EGRESS_MODE=whitelist` |
| Inter-domain exchange forbidden by default (§3.18) | Built-in | all-pairs DROP; nothing crosses unless a diode is explicitly configured |
| Unidirectional, mediated, logged file diode (§3.18) | Opt-in | `DIODES="src>dst …"` + `src/environments.sh diode`: host-mediated, per-file accept, sha256+direction logged, optional content scan |
| Peripheral compartmentalization (USB) | Built-in | usbguard default-deny; whitelist with `src/host.sh usb-allow`; YubiKey routed to one VM |
| No secrets left at rest | Built-in | `src/environments.sh scrub-secrets` blanks passwords/keys after setup |
| Traceability of security events | Built-in | append-only audit log (`/var/log/appliance-audit.log`): isolation transitions, portal logins, USB routing, updates |
| Memory encryption (anti cold-boot) | Opt-in | `mem_encrypt=on` set; full DRAM encryption needs TSME enabled in firmware |
| Disk encryption | Opt-in | LUKS2 via `ENCRYPT=1`; explicit `LUKS_PASS` required |
| Per-environment user-keyed encryption | Opt-in | per-VM LUKS via `<env>_ENCRYPT_DISK=1` + `<env>_DISK_PASS` |
| Dedicated non-bypassable VPN per environment | Opt-in | host-enforced WireGuard via `<env>_VPN=1` + `src/environments.sh vpn` |
| Secure/measured boot + TPM | Opt-in | `src/host.sh secure-boot` (Secure Boot + TPM PCR bind) + `src/host.sh tpm-initramfs-hook` |

The opt-in items are left off by default for good reason: some depend on a
firmware toggle the OS can't set (memory encryption needs TSME in the BIOS), and
some are powerful but brick-prone enough that they should be tested on a spare
machine first (Secure Boot key enrollment, TPM-bound unlock, full-disk
encryption).

## Development

Every script is `set -euo pipefail` (or `set -eu` for the POSIX `src/lib.sh`),
checks for root and its dependencies, and is safe to re-run. Continuous
integration runs [ShellCheck](https://www.shellcheck.net/) and the test suite on
every push and pull request; ShellCheck fails on warnings and above. Run both
locally before opening a PR:

```sh
shellcheck -x -S warning configure.sh setup.sh flash.sh src/*.sh tests/*.sh
./tests/run.sh
```

### Tests

`./tests/run.sh` runs the suite inside a privileged Alpine container — the same
distro the appliance is built on — because the scripts under test really do
configure a host: they load nftables rules, write to `/etc`, and create users.
The container makes that safe and disposable, and means the assertions are about
real behaviour rather than a mock:

- the generated nftables rulesets are **loaded into a real kernel**, so a rule
  the kernel would reject cannot pass;
- the generated cloud-init seed is read back out of the ISO and **parsed as
  YAML**, so a concatenation slip in `create.sh` fails the build;
- libvirt, the network stack and the display server are replaced by recording
  stubs in `tests/stubs/`, which also let a test simulate an isolation breach, a
  guest agent that never answers, or a detach that libvirt refuses.

```sh
./tests/run.sh              # everything
./tests/run.sh isolate      # one file (tests/test-isolate.sh)
IN_CONTAINER=1 ./tests/run.sh    # already on a suitable Linux host, as root
```

| File | Covers |
|------|--------|
| `tests/test-common.sh`  | the environment model, `config.env` handling, secret generation and scrubbing |
| `tests/test-create.sh`  | VM creation, cloud-init generation, DE/integration wiring, supply-chain guards |
| `tests/test-windows.sh` | the Windows 11 office path: the q35+UEFI+vTPM virt-install profile, the media it attaches, the generated autounattend.xml, and the no-ISO fail-closed |
| `tests/test-isolate.sh` | the isolation ruleset, egress policy, and the verification result |
| `tests/test-host.sh`    | hardening, the kiosk desktop, switching/trust bar, Wi-Fi, captive portal |
| `tests/test-ops.sh`     | the setup menu, USB routing, password changes, VPN, secret scrubbing |
| `tests/test-audit.sh`   | the audit log: append-only, rotation, the unprivileged spool, never aborting its caller |
| `tests/test-watch.sh`   | the isolation watch: status-file contract, transitions, the recurring timer |
| `tests/test-configure.sh` | the build-machine wizard: defaults mode, piped answers, config.env backup/atomicity, interrupt safety |
| `tests/test-flash.sh` | the flash entry point: image reuse, conversion, and the disk-safety refusals (system disk, unknown disk, bad confirmation) |
| `tests/test-compliance.sh` | the post-install compliance gate: verdict, missing-step detection, boot-block marker |
| `tests/test-maint.sh` | the maintenance tools: package/SBOM run and the secure-erase dry-run guard |

## Security

Isolation between environments is the core guarantee of this project. Secrets live
only in the git-ignored `config.env` or on the appliance — never in the repository
or a shipped image.

Supply-chain integrity:

- **Base cloud images.** Pinning is optional but strict once set, and comes in
  two forms: pin the vendor's own signature (`<OS>_IMG_GPG_FPR`, verified on
  every run against exactly that key), or pin a build by hand
  (`<OS>_IMG_SHA256` — this wins when both are set). With neither, the image
  downloads unverified and prints a warning; a failed verification deletes the
  file and aborts. Pair a hand-pinned hash with `<OS>_IMG_DATE` (the vendor's
  dated, immutable directory) or it goes stale on the next vendor rebuild.
  `REQUIRE_IMG_SHA256=1` makes a missing pin a hard error.
- **Appliance updates.** `src/host.sh update` fails closed: with no
  `UPDATE_GPG_FPR` pinned it refuses to install anything, because an unverified
  "download and run as root" is a remote root shell for whoever answers the
  URL. `UPDATE_INSECURE=1` is an explicit operator downgrade, not a supported
  configuration.
- **Third-party apt keys.** `src/environments.sh create` refuses to trust a Microsoft
  or Wazuh signing key whose fingerprint doesn't match the pinned value after
  import, and refuses to build the seed at all if you blank a fingerprint that
  the current config needs.

`src/host.sh harden` always sets `PermitEmptyPasswords no` and denies the
passwordless kiosk console account over SSH, regardless of the
`HARDEN_INPUT`/`HOST_SSH` firewall settings.

`config.env` is kept at mode `0600` — it holds the guest and root passwords, the
Wi-Fi PSK and the LUKS/WireGuard keys, and the kiosk desktop user must never be
able to read it. Every write goes back through that mode, and a root-run script
tightens the file if it finds it loose.

## License

Released under the [MIT License](LICENSE).
