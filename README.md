# multilevel — NixOS edition

[![shellcheck](https://github.com/sltcnb/multilevel-multiusage-desktop/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/sltcnb/multilevel-multiusage-desktop/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![NixOS](https://img.shields.io/badge/NixOS-flake-5277C3?logo=nixos&logoColor=white)](https://nixos.org/)
[![ANSSI PA-114](https://img.shields.io/badge/aligned-ANSSI--PA--114-002654)](https://cyber.gouv.fr/)

A locked-down laptop that runs several separate worlds side by side and lets you
flip between them with a single keystroke. Each world is its own KVM virtual
machine — its own OS, network and disk — and **they cannot talk to each other**:
one can be compromised without putting the others at risk. It targets the French
cybersecurity agency's guidance for multi-environment workstations
(**ANSSI-PA-114**).

| Hotkey    | Environment        | Purpose                        | Default OS | Desktop |
|-----------|--------------------|--------------------------------|------------|---------|
| `Super+1` | **office**         | Everyday work, email, browsing | Ubuntu     | GNOME   |
| `Super+2` | **development**    | Coding, dev tools              | Arch       | GNOME   |
| `Super+3` | **administration** | Sensitive/admin tasks          | Arch       | GNOME   |

> ### 🧩 This is the `nixos` branch
> Here the **host** (the socle / trusted computing base) is a **declarative
> NixOS flake**. The original Alpine + POSIX-shell implementation — `config.env`,
> `./build/make-image.sh`, `./setup.sh`, `./environments/create.sh` — lives on
> the **`main`** branch. If you landed here looking for the bash appliance, check
> out `main`. Everything below describes the NixOS port and how to work on it.

---

## Contents

- [Mental model](#mental-model) — what the port is and isn't
- [How the isolation works](#how-the-isolation-works)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started) — install Nix, the dev shell
- [The dev loop](#the-dev-loop) — edit → evaluate → inspect → build
- [Working on an environment](#working-on-an-environment) — a worked example
- [Building the image](#building-the-image)
- [Deploying to hardware](#deploying-to-hardware)
- [The config, before and after](#the-config-before-and-after)
- [Secrets](#secrets)
- [Contributing](#contributing)
- [Roadmap / deferred](#roadmap--deferred)
- [Status](#status)

---

## Mental model

The bash appliance was already a **declarative spec applied imperatively**:
`config.env` plus ~20 idempotent, re-runnable `set -euo pipefail` scripts that
detect hardware, install packages, write config and verify. That is exactly what
Nix does natively — so this branch collapses the host into a **typed module**
plus a **per-machine config**.

Two boundaries define the scope:

- **Host-only.** Only the socle becomes NixOS. Atomic upgrades, rollback and
  reproducible image builds all come for free — the payoff for the TCB you most
  want to trust.
- **Guests stay cloud images.** office/development/administration remain
  OS-vendor **cloud images** provisioned by cloud-init. This is deliberate:
  office *must* be Ubuntu (Microsoft Intune/Entra is Ubuntu-only), and cloud-init
  keeps every guest OS on one uniform path. NixOS only **declares** the libvirt
  domains; it does not replace the guest OSes.

The unit of everything is an **environment**. Each has an explicit `index`
(1-based) that fixes — permanently and independently of the others — its:

| Derived from `index` | Value for index `i` | Example (office, i=1) |
|---|---|---|
| workspace / hotkey    | `i`                     | `Super+1`        |
| /24 subnet            | `<subnetBase>.i.0/24`   | `10.10.1.0/24`   |
| host gateway          | `<subnetBase>.i.1`      | `10.10.1.1`      |
| libvirt network       | `isol-<name>`           | `isol-office`    |
| bridge interface      | `virbr<i>`              | `virbr1`         |

Assign `index` once; enabling or disabling other environments never renumbers
it. This ANSSI stability requirement used to be a comment — now it's a typed
assertion.

## How the isolation works

Every environment reaches the internet; none can reach another, and that holds
even if a layer fails. It is all enforced on the host:

- **Separate L2 segments** — one Linux bridge + one /24 per environment.
- **All-pairs drop in nftables** — the `inet appliance_isol` table's forward
  chain (priority −1, *ahead* of libvirt's own rules) drops every ordered pair
  of environment subnets **and**, redundantly, every ordered pair of bridge
  names. Knock out one rule form and the other still holds.
- **libvirt per-network filtering** is a third independent layer.

Outbound is plain NAT masquerade. Any environment can be tightened to a
whitelist (`egress.mode = "whitelist"`) — DNS to its gateway plus a fixed
IP/CIDR set, everything else dropped — handy for the sensitive `administration`
VM. This ruleset is **generated from the environment list** and verified by a
NixOS VM test (`nix flake check`) rather than only on hardware.

## Repository layout

```
flake.nix / flake.lock            inputs/outputs: nixosConfigurations, image, checks, devShell
nix/
  lib/environments.nix            pure derivations (index → workspace/subnet/bridge/…)
  modules/appliance/
    default.nix                   top-level `appliance.*` options + module wiring
    environments.nix              the typed environment model + structural assertions
    host.nix                      libvirtd, KVM/nested virt, kiosk user, sysctl
    networking.nix                libvirt nets + `inet appliance_isol` nftables (all-pairs drop + NAT)
    desktop.nix                   autologin → startx → i3, virt-viewer, polybar trust bar, keyd
    guests.nix                    first-boot provisioner: resource split, cloud-init seed, domain define
  hosts/appliance/
    configuration.nix             THE file you edit — the config.env replacement
    hardware.nix                  placeholder; replace with `nixos-generate-config` on real hardware
tests/isolation.nix               NixOS VM test asserting the cross-env drop ruleset
build/nixos-build.sh              build the image on an x86_64-linux workstation
```

Each appliance module maps to scripts on `main`: `host.nix` ←
`detect-and-install.sh`+`configure.sh`+`harden.sh`; `networking.nix` ←
`isolate.sh`; `desktop.nix` ← `configure.sh`+`switching.sh`; `guests.nix` ←
`create.sh`. Those bash scripts are still in the tree as the reference the port
was validated against.

## Getting started

You need **Nix with flakes**. If you don't have it:

```sh
# macOS or Linux — Determinate installer (enables flakes, clean uninstall)
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Then clone and drop into the dev shell (formatters + linters; works on macOS
too):

```sh
git clone <repo-url> multilevel && cd multilevel && git checkout nixos
nix develop          # provides nixpkgs-fmt, statix, deadnix, shellcheck
```

> **One thing to know up front:** the appliance is `x86_64-linux`. You can
> **evaluate** the whole flake from any machine (including an Apple-silicon Mac)
> — that catches every option/type/assertion error and lets you inspect the
> generated config. But **building** the image or **running** the VM test needs
> an `x86_64-linux` builder. See [Building the image](#building-the-image).

## The dev loop

Most work is: edit a module or the config, then **evaluate and inspect** — no
build, no hardware, fast, works on any OS.

**1. Evaluate the whole system** (forces every module, type and assertion):

```sh
nix eval .#nixosConfigurations.appliance.config.system.build.toplevel.drvPath
```

A `/nix/store/….drv` path means it evaluated cleanly; an error points you at the
offending option.

**2. Check every flake output at once** (no builds):

```sh
nix flake check --no-build
```

**3. Inspect what the modules actually generate.** These read pure string values,
so they work even on macOS:

```sh
# the isolation ruleset — the crown jewel; eyeball the drops/NAT/whitelist
nix eval --raw .#nixosConfigurations.appliance.config.networking.nftables.tables.appliance_isol.content

# the keyd hotkey map
nix eval --json .#nixosConfigurations.appliance.config.services.keyd.keyboards.default.settings.main
```

Files (i3 config, polybar scripts, the guest provisioner) are derivations: on an
`x86_64-linux` box you can realise and read them, e.g.

```sh
cat "$(nix build --no-link --print-out-paths \
  .#nixosConfigurations.appliance.config.services.xserver.windowManager.i3.configFile)"
```

**4. Format & lint before committing:**

```sh
nix fmt                          # nixpkgs-fmt over the tree
statix check . && deadnix .      # Nix anti-patterns / dead code
```

## Working on an environment

Everything an operator changes lives in `nix/hosts/appliance/configuration.nix`.
To add a fourth, isolated `lab` environment on Debian with a locked-down egress:

```nix
appliance.environments.lab = {
  index = 4;                       # → Super+4, 10.10.4.0/24, virbr4 (stable forever)
  os = "debian";
  desktop = "xfce4";
  egress = {
    mode = "whitelist";            # DNS + the list below only; everything else dropped
    allow = [ "10.20.0.0/16" "1.1.1.1" ];
  };
};
```

Re-evaluate (`nix eval …toplevel.drvPath`) and the assertions catch mistakes
immediately — a duplicate `index`, `intune = true` on a non-Ubuntu guest, a
`vpn.enable` without its keys, or `wazuh = true` without `appliance.wazuhManager`.
Dump the ruleset (dev-loop step 3) to confirm `lab` is fenced from 1/2/3 and its
whitelist renders as you expect.

To disable an environment without renumbering the rest: `enable = false;`.

See `nix/modules/appliance/environments.nix` for every per-environment option
(`os`, `desktop`, `egress`, `intune`, `msApps`, `wazuh`, `vpn.*`, `encryptDisk`,
and `memoryMB`/`vcpus`/`diskGB` overrides — `null` = auto-split at first boot).

## Building the image

The appliance is `x86_64-linux`, so build on — or offload to — an
`x86_64-linux` machine. Three ways, pick one:

**A. On an x86_64-linux workstation (recommended).** Copy/clone this branch onto
the box and run the helper. It installs Nix if missing, enables flakes, builds
the image (which also runs the guest-provisioner ShellCheck gate) and prints
flashing instructions:

```sh
./build/nixos-build.sh                 # raw-efi disk image
./build/nixos-build.sh --iso           # installer ISO instead
./build/nixos-build.sh --check         # also run the isolation VM test (needs KVM)
./build/nixos-build.sh --install-nix   # install Nix first if the box has none
```

By hand: `nix build .#packages.x86_64-linux.image`.

**B. Remote builder, driving from a Mac.** Build from macOS but offload the
x86_64 work to the workstation over SSH. Add the builder on the Mac in
`/etc/nix/machines` (and put yourself in `nix.settings.trusted-users`):

```
ssh-ng://you@workstation x86_64-linux ~/.ssh/id_ed25519 8 1 kvm,big-parallel
```

The workstation just needs Nix + your SSH key in `authorized_keys`. Then build
with the **fully-qualified attribute** — plain `.#image` resolves to the empty
`aarch64-darwin` package set on a Mac and fails:

```sh
nix store ping --store ssh-ng://you@workstation   # verify the builder
nix build .#packages.x86_64-linux.image
```

**C. Local Linux VM builder (nix-darwin).** If the Mac runs nix-darwin, set
`nix.linux-builder.enable = true;` then `nix build .#packages.x86_64-linux.image`
transparently offloads to the managed VM.

### Running the isolation test

```sh
nix flake check                          # boots a VM headless and asserts isolation
# or just:  nix build .#checks.x86_64-linux.isolation -L
```

## Deploying to hardware

1. **Generate the real hardware config** on the target and replace the
   placeholder: `nixos-generate-config --show-hardware-config > nix/hosts/appliance/hardware.nix`.
2. **Flash** the built image to a USB stick (`lsblk` to find the device, then
   `sudo dd if=<image> of=/dev/sdX bs=4M status=progress conv=fsync`), boot the
   target from it (UEFI; Secure Boot off for now), and install onto the internal
   disk.
3. **Iterate** with atomic switches: `sudo nixos-rebuild switch --flake .#appliance`.
   Every switch is a new boot-menu generation — a bad change rolls back by
   selecting the previous one. This is the single biggest win over the bash
   appliance.

## The config, before and after

`config.env` (on `main`):
```sh
ENVS="office development administration"
office_ENABLED=1; office_OS="ubuntu"; office_DE="gnome"; office_INTUNE=1
```
→ `nix/hosts/appliance/configuration.nix` (here):
```nix
appliance.environments.office = {
  index = 1;          # fixes workspace 1, subnet 10.10.1.0/24, bridge virbr1
  os = "ubuntu";      # enum; asserted == "ubuntu" because intune = true
  desktop = "gnome";
  intune = true;
};
```

The hand-rolled machinery on `main` has a native counterpart here:

| Hand-rolled on `main` | Native on `nixos` |
|---|---|
| `set_kv` idempotent upsert into `config.env` | the module system |
| "safe to re-run" scripts | declarative convergence |
| `resolve_secret` (generate + record + scrub) | sops-nix / agenix |
| `$ENVS` + `${env}_*` string parsing | typed `appliance.environments.<name>` |
| `env_index` / `env_subnet` / `env_bridge` | pure Nix in `nix/lib/environments.nix` |
| build via privileged Docker + Alpine | `nixos-generators` (reproducible) |
| experimental `secure-boot.sh` | `lanzaboote` *(deferred)* |
| on-hardware `isolate.sh` PASS/FAIL | a NixOS VM test in CI |

## Secrets

The bash branch generates secrets, records them to `/root/generated-secrets.txt`,
then scrubs `config.env`. The Nix equivalent is **sops-nix** or **agenix**:
declare `appliance.guest.passwordFile` (and the VPN / LUKS key paths) to point at
a decrypted runtime path under `/run`. Secret paths are typed `str`, **not**
`path`, on purpose — a `path` would copy the secret into the world-readable Nix
store.

## Contributing

- **Format & lint Nix:** `nix fmt`, `statix check .`, `deadnix .` (all in
  `nix develop`).
- **Shell:** any embedded/committed shell still passes ShellCheck at
  `-S warning` (CI gate, and `writeShellApplication` enforces it at build time).
- **Every change must `nix flake check`** — the isolation test is the guardrail;
  don't weaken it to make a change pass.
- Keep `index` values stable and the isolation ruleset generated-from-the-list —
  never hand-write per-environment drops.

## Roadmap / deferred

Faithfully ported so far: the environment model, the isolation ruleset
(all-pairs subnet + bridge drops, NAT, per-env egress whitelist), libvirt
networks, the kiosk desktop + trust bar + keyd switching, and guest domain
provisioning with cloud-init.

Still TODO (parity with `main`):

- **Guest DE install** is best-effort; port `create.sh`'s self-healing,
  retry-until-online installer + display-manager autologin.
- **Enterprise integrations** — Intune/Entra prep, Outlook/Teams Edge PWAs,
  Wazuh enrollment (options exist; provisioning not wired).
- **Opt-in hardening** — per-env WireGuard (options exist, enforcement not
  wired), per-VM & full-disk LUKS, Secure Boot/TPM via **lanzaboote**, memory
  encryption.
- **USB** — usbguard default-deny + YubiKey→VM routing.
- **Captive portal** helper (`Super+p` currently just switches to the portal
  workspace).
- **Deeper isolation test** — boot with nested guests and reproduce the in-guest
  ping matrix via the qemu-guest-agent.
- **Base-image integrity** — switch to `pkgs.fetchurl` with pinned SHA256 so base
  images are reproducible store paths.
- **Drop the `nixos-generators` input** — it's upstreamed into nixpkgs as of
  25.05; move to the native image builder.

## Status

**Evaluates clean.** `nix flake check --no-build` passes; the full system, the
`image`, and the `isolation` check all evaluate — every module, type and
assertion. The generated nftables ruleset was inspected for both egress modes
and matches `isolate.sh`.

**Not yet built/booted.** Building `.#image` and running the VM test need an
`x86_64-linux` builder; expect to iterate on runtime specifics a static eval
can't reach — especially the `startx → i3` autologin path and the libvirt
networks/guests services. `flake.lock` pins `nixpkgs` at nixos-25.05.

## License

Released under the [MIT License](LICENSE).
