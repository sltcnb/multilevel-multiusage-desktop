#!/usr/bin/env bash
# build/nixos-build.sh
# -----------------------------------------------------------------------------
# Build the NixOS appliance image on an x86_64-linux workstation.
#
# Copy/clone this repo (branch `nixos`) onto the workstation and run:
#     ./build/nixos-build.sh                # build the raw-efi disk image
#     ./build/nixos-build.sh --iso          # build the installer ISO instead
#     ./build/nixos-build.sh --check        # also run the isolation VM test (needs KVM)
#     ./build/nixos-build.sh --install-nix   # install Nix first if it is missing
#
# Building the image also realises the guest provisioner, which is a
# `writeShellApplication` — so ShellCheck runs on it as part of the build.
# From macOS, don't run this here: build on a Linux box (this script) or set up
# a remote builder — see README-nixos.md.
# -----------------------------------------------------------------------------
set -euo pipefail

log() { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok() { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2
  exit 1
}

FLAKE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_CHECK=0
INSTALL_NIX=0
TARGET="image" # or installer-iso

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) RUN_CHECK=1 ;;
    --install-nix) INSTALL_NIX=1 ;;
    --iso) TARGET="installer-iso" ;;
    -h | --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

# --- host sanity -------------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || die "Run on the x86_64-linux workstation, not $(uname -s). From macOS use a remote/Linux builder (README-nixos.md)."
[ "$(uname -m)" = "x86_64" ] || warn "Arch is $(uname -m); the appliance targets x86_64-linux. The build will need binfmt emulation or a remote x86_64 builder."

# --- ensure nix --------------------------------------------------------------
NIX_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
if ! command -v nix >/dev/null 2>&1 && [ -e "$NIX_PROFILE" ]; then
  # shellcheck source=/dev/null
  . "$NIX_PROFILE"
fi

if ! command -v nix >/dev/null 2>&1; then
  install_nix() {
    log "Installing Nix (Determinate installer; will use sudo)…"
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm
    # shellcheck source=/dev/null
    . "$NIX_PROFILE"
  }
  if [ "$INSTALL_NIX" = 1 ]; then
    install_nix
  elif [ -t 0 ]; then
    printf '%s' "Nix not found. Install it now via the Determinate installer? [y/N] " >&2
    read -r ans
    case "$ans" in
      [yY]*) install_nix ;;
      *) die "Nix is required. Re-run with --install-nix, or install it manually." ;;
    esac
  else
    die "Nix not found. Install it (https://install.determinate.systems/nix) or re-run with --install-nix."
  fi
fi

# Pass flakes on the command line so this works even if the daemon config has
# not enabled them (a plain upstream Nix install).
NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

log "Using $(nix "${NIX_FLAGS[@]}" --version)"
cd "$FLAKE_DIR"

# --- optional: the isolation VM test ----------------------------------------
if [ "$RUN_CHECK" = 1 ]; then
  log "Running the isolation VM test (boots a VM; needs KVM)…"
  nix "${NIX_FLAGS[@]}" build -L ".#checks.x86_64-linux.isolation"
  ok "Isolation test passed."
fi

# --- build the image ---------------------------------------------------------
# Fully-qualified attr so it resolves regardless of the builder's own arch.
ATTR=".#packages.x86_64-linux.${TARGET}"
log "Building ${ATTR} (also runs the guest-provisioner ShellCheck gate)…"
OUT="$(nix "${NIX_FLAGS[@]}" build "$ATTR" --no-link --print-out-paths)"
ok "Built store path: $OUT"

IMG="$(find -L "$OUT" -maxdepth 2 \( -name '*.img' -o -name '*.raw' -o -name '*.iso' \) 2>/dev/null | head -n1 || true)"
if [ -n "$IMG" ]; then
  ok "Image: $IMG"
  printf '%s\n' "
Flash it to a USB stick on this Linux box (DOUBLE-CHECK the device — this wipes it):
    lsblk                                   # find your USB, e.g. /dev/sdX
    sudo dd if='$IMG' of=/dev/sdX bs=4M status=progress conv=fsync
    sync
Then boot the target from the stick (UEFI; Secure Boot off for now).
" >&2
else
  warn "No .img/.raw/.iso found under $OUT — inspect it: ls -R $OUT"
fi
