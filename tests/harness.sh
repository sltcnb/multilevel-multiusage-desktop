#!/bin/sh
# tests/harness.sh — build a throwaway copy of the appliance tree plus a
# predictable config.env, so each test file starts from the same state and never
# touches the developer's real config.
#
# REPO_ROOT is the checkout under test; SANDBOX is the per-test copy the scripts
# actually run from (they resolve APP_ROOT from their own location).

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STUBS="$REPO_ROOT/tests/stubs"
SANDBOX=""

# Stubs must win over anything the container really has installed, except where
# a test deliberately wants the real binary (nft, qemu-img, gpg, sha256sum).
PATH="$STUBS:$PATH"; export PATH

new_sandbox() {
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  for d in lib host environments installer build; do
    mkdir -p "$SANDBOX/$d"
    cp "$REPO_ROOT/$d"/* "$SANDBOX/$d/" 2>/dev/null || true
  done
  cp "$REPO_ROOT/setup.sh" "$SANDBOX/setup.sh"
  cp "$REPO_ROOT/config.env.example" "$SANDBOX/config.env.example"
  chmod +x "$SANDBOX"/*/*.sh "$SANDBOX/setup.sh" 2>/dev/null || true

  STUB_LOG="$SANDBOX/stub.log"; : > "$STUB_LOG"
  STUB_STATE="$SANDBOX/stub-state"; mkdir -p "$STUB_STATE"
  export STUB_LOG STUB_STATE

  write_config
}

# A deterministic three-environment config: one apt guest, two arch guests,
# matching the shipped default layout.
write_config() {
  cat > "$SANDBOX/config.env" <<EOF
ENVS="office development administration"
SUBNET_BASE="10.10"
IMAGES_DIR="$SANDBOX/images"
CACHE_DIR="$SANDBOX/cache"

office_ENABLED=1;         office_OS="ubuntu";        office_DE="gnome"
development_ENABLED=1;    development_OS="arch";     development_DE="xfce4"
administration_ENABLED=1; administration_OS="arch";  administration_DE="none"

office_VCPU=2;         office_RAM_MB=2048;         office_DISK_GB=20
development_VCPU=2;    development_RAM_MB=2048;    development_DISK_GB=20
administration_VCPU=2; administration_RAM_MB=2048; administration_DISK_GB=20

office_EGRESS_MODE="all";              office_EGRESS_ALLOW=""
development_EGRESS_MODE="all";         development_EGRESS_ALLOW=""
administration_EGRESS_MODE="all";      administration_EGRESS_ALLOW=""

office_DISK_PASS=""
GUEST_USER="operator"
GUEST_PASSWORD="testpw123"
HOST_ROOT_PASSWORD="rootpw123"
WIFI_PSK="wifipsk123"
LUKS_PASS=""
KIOSK_USER="kiosk"
KEYBOARD_LAYOUT="us"
TRUST_BAR=1
USBGUARD=0
YUBIKEY_ROUTER=0
HARDEN_INPUT=0
HOST_SSH=0
WAN_IFACE="auto"
EOF
  mkdir -p "$SANDBOX/images" "$SANDBOX/cache"
}

# cfg_set KEY VALUE — edit the sandbox config the way an operator would.
cfg_set() {
  grep -v "^$1=" "$SANDBOX/config.env" > "$SANDBOX/config.env.t" || true
  printf '%s="%s"\n' "$1" "$2" >> "$SANDBOX/config.env.t"
  mv "$SANDBOX/config.env.t" "$SANDBOX/config.env"
}
