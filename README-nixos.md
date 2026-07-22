# multilevel — NixOS port (branch `nixos`)

This branch reimplements the **host** (the socle / TCB) as a declarative NixOS
flake. The `config.env` + ~20 idempotent bash scripts that *detect, install,
write config, verify and re-run* are exactly the problem Nix solves natively, so
the whole appliance collapses into a typed module plus a per-machine config.

**Scope (host-only, MVP first).** The guests stay OS-vendor **cloud images**
provisioned by cloud-init — deliberate: office *must* be Ubuntu (Intune/Entra),
and cloud-init keeps every guest OS on one uniform path. NixOS only *declares*
the domains. This first pass targets the MVP: **host boots → N isolated VMs +
trust bar + `Super+1/2/3` switching.** See *Deferred* below.

## Why NixOS fits

| Hand-rolled in the bash branch | Native in NixOS |
|---|---|
| `set_kv` idempotent upsert into `config.env` | the module system |
| "every script is `set -euo pipefail` and safe to re-run" | declarative convergence |
| `resolve_secret` (generate + record + scrub) | sops-nix / agenix |
| `$ENVS` + `${env}_*` string parsing | typed `appliance.environments.<name>` |
| `env_index` / `env_subnet` / `env_bridge` | pure Nix in `nix/lib/environments.nix` |
| build via privileged Docker + Alpine | `nixos-generators` (reproducible) |
| experimental `secure-boot.sh` | `lanzaboote` (maintained) — *deferred* |
| on-hardware `isolate.sh` PASS/FAIL checks | a NixOS VM test in CI (`nix flake check`) |

## Layout

```
flake.nix                         inputs/outputs: nixosConfigurations, image, checks, devShell
nix/lib/environments.nix          pure derivations (index → workspace/subnet/bridge/…)
nix/modules/appliance/
  default.nix                     top-level `appliance.*` options + module wiring
  environments.nix                the typed environment model + structural assertions
  host.nix                        libvirtd, KVM/nested virt, kiosk user, sysctl  (detect-and-install + configure + harden)
  networking.nix                  libvirt nets + `inet appliance_isol` nftables (all-pairs drop + NAT)  (isolate.sh)
  desktop.nix                     autologin → startx → i3, virt-viewer, polybar trust bar, keyd  (configure + switching.sh)
  guests.nix                      first-boot provisioner: resource split, cloud-init seed, domain define  (create.sh)
nix/hosts/appliance/
  configuration.nix               THE file an operator edits — the config.env replacement
  hardware.nix                    placeholder; replace with `nixos-generate-config` on real hardware
tests/isolation.nix               NixOS VM test asserting the cross-env drop ruleset
```

## The config, before and after

`config.env`:
```sh
ENVS="office development administration"
office_ENABLED=1; office_OS="ubuntu"; office_DE="gnome"; office_INTUNE=1
```
→ `nix/hosts/appliance/configuration.nix`:
```nix
appliance.environments.office = {
  index = 1;          # fixes workspace 1, subnet 10.10.1.0/24, bridge virbr1
  os = "ubuntu";      # enum; asserted == "ubuntu" because intune = true
  desktop = "gnome";
  intune = true;
};
```
`index` replaces positional ordering: assign it once and it never renumbers when
you enable/disable other environments (the ANSSI stability requirement, now
enforced by an assertion instead of a comment).

## Build & run

Requires Nix with flakes. On the appliance itself:
```sh
sudo nixos-rebuild switch --flake .#appliance      # atomic; rollback via the boot menu
```

### Build the flashable image

The appliance is `x86_64-linux`, so the image must be built on (or offloaded to)
an `x86_64-linux` machine. Three ways, pick one:

**A. On an x86_64-linux workstation (recommended).** Copy/clone this branch onto
the box and run the helper — it installs Nix if missing, enables flakes, builds
the image (which also runs the guest-provisioner ShellCheck gate), and prints
flashing instructions:
```sh
./build/nixos-build.sh                 # raw-efi disk image
./build/nixos-build.sh --iso           # installer ISO instead
./build/nixos-build.sh --check         # also run the isolation VM test (needs KVM)
./build/nixos-build.sh --install-nix   # install Nix first if the box has none
```
Equivalent by hand: `nix build .#packages.x86_64-linux.image`.

**B. Remote builder, driving from the Mac.** Keep running `nix build .#image`
on macOS but offload the x86_64 build to the workstation over SSH. On the Mac,
add to `/etc/nix/machines` (and `nix.settings.trusted-users` must include you):
```
ssh-ng://you@workstation x86_64-linux ~/.ssh/id_ed25519 8 1 kvm,big-parallel
```
The workstation just needs Nix + your SSH key in `authorized_keys`. Test with
`nix store ping --store ssh-ng://you@workstation`.

**C. Local Linux VM builder (nix-darwin).** If the Mac runs nix-darwin:
```nix
nix.linux-builder.enable = true;
nix.settings.trusted-users = [ "@admin" ];
```
then `nix build .#image` transparently offloads to the managed VM.

Run the isolation test (headless, no hardware, no nested KVM):
```sh
nix flake check              # or: nix build .#checks.x86_64-linux.isolation
```

Dev shell (formatters + linters, works on macOS too):
```sh
nix develop
```

## Secrets

The bash branch generates secrets, records them to
`/root/generated-secrets.txt`, then scrubs `config.env`. The Nix equivalent is
**sops-nix** or **agenix**: declare `appliance.guest.passwordFile` (and the VPN /
LUKS key paths) to point at a decrypted runtime path under `/run`. Secret paths
are typed `str`, **not** `path`, on purpose — a `path` would copy the secret into
the world-readable Nix store.

## Deferred (not in this MVP)

Faithfully ported: the environment model, the isolation ruleset (all-pairs
subnet + bridge drops, NAT, per-env egress whitelist), libvirt networks, the
kiosk desktop + trust bar + keyd switching, and guest domain provisioning with
cloud-init.

Still TODO (tracked against parity with the bash branch):

- **Guest DE install** is best-effort here; port `create.sh`'s self-healing,
  retry-until-online installer + display-manager autologin.
- **Enterprise integrations**: Intune/Entra prep, Outlook/Teams Edge PWAs, Wazuh
  enrollment (options exist; provisioning not wired).
- **Opt-in hardening**: per-env WireGuard (`vpn.*` options exist, enforcement not
  wired), per-VM LUKS, full-disk LUKS, Secure Boot/TPM via **lanzaboote**,
  memory encryption.
- **USB**: `usbguard` default-deny + YubiKey→VM routing.
- **Captive portal** helper (`Super+p` currently just switches to the portal
  workspace).
- **Deeper isolation test**: boot with nested guests and reproduce the in-guest
  ping matrix via the qemu-guest-agent.
- **Base-image integrity**: switch to `pkgs.fetchurl` with the pinned SHA256 so
  base images are reproducible store paths (the vendors' "latest" URLs make the
  pin go stale — same tradeoff the bash branch documents).

## Status

**Evaluates clean.** `nix flake check --no-build` passes; the full system
(`nixosConfigurations.appliance`), the `image`, and the `isolation` check all
evaluate — every module, type and assertion. The generated nftables ruleset was
inspected for both egress modes and matches `isolate.sh` (all-pairs subnet +
bridge drops, NAT, and the whitelist DNS/allow-set/default-deny chain).

**Not yet built/booted.** Building `.#image` and running the VM test need an
`x86_64-linux` builder (see cross-build note above); the VM test is also what
triggers the `writeShellApplication` shellcheck gate on the guest provisioner.
Expect to iterate on runtime specifics a static eval can't reach — especially
the `startx → i3` autologin path and the libvirt networks/guests services.

`flake.lock` pins `nixpkgs` at nixos-25.05 and `nixos-generators`; commit it with
the scaffold. (nixos-generators now warns it's deprecated — upstreamed into
nixpkgs as of 25.05 — so a future cleanup can drop that input for the native
image builder.)
