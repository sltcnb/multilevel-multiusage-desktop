#!/bin/sh
# tests/test-flash-image.sh — the build+flash entry point (flash-image.sh).
#
# flash-image.sh runs on the BUILD host and dd's onto a real disk, so the tests
# run it against a staged tree with every dangerous command (qemu-img, lsblk,
# findmnt, umount, dd) replaced by a stub that only logs its arguments. The
# point of the suite is the SAFETY contract: the system disk and unknown disks
# must be refused, and a mismatched confirmation must stop before dd.
set -u
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== flash-image.sh =="

# stage — throwaway tree: the script, the library it sources, a fake built
# image, and a bin/ of stubs that shadows the real disk tools.
stage() {
  STAGE="$(mktemp -d)"
  mkdir -p "$STAGE/src/lib" "$STAGE/out" "$STAGE/bin"
  cp "$REPO_ROOT/src/lib/common.sh" "$STAGE/src/lib/common.sh"
  cp "$REPO_ROOT/flash-image.sh" "$STAGE/flash-image.sh"
  printf 'FAKE-QCOW2\n' > "$STAGE/out/appliance-alpine.qcow2"
  STUB_LOG="$STAGE/stub.log"; : > "$STUB_LOG"

  cat > "$STAGE/bin/qemu-img" <<'EOF'
#!/bin/sh
printf 'qemu-img %s\n' "$*" >> "$STUB_LOG"
# qemu-img convert -O raw IN OUT — produce the output file
eval "printf 'FAKE-RAW\n' > \"\${$#}\""
EOF

  # Two disks: sda = internal system disk (RM=0), sdb = removable USB (RM=1).
  cat > "$STAGE/bin/lsblk" <<'EOF'
#!/bin/sh
printf 'lsblk %s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *PKNAME*)                       printf 'sda\n' ;;
  *"NAME,SIZE,TYPE,RM,MODEL"*)    printf '/dev/sda 500G disk 0 INTERNAL\n/dev/sdb 14G disk 1 USBSTICK\n' ;;
  *"NAME,TYPE,RM"*)               printf '/dev/sda disk 0\n/dev/sdb disk 1\n' ;;
  *"NAME,TYPE"*)                  printf '/dev/sda disk\n/dev/sdb disk\n' ;;
  *-lnpo*)                        printf '/dev/sdb\n/dev/sdb1\n' ;;
esac
EOF

  cat > "$STAGE/bin/findmnt" <<'EOF'
#!/bin/sh
printf 'findmnt %s\n' "$*" >> "$STUB_LOG"
printf '/dev/sda1\n'
EOF

  for c in umount dd udisksctl; do
    cat > "$STAGE/bin/$c" <<EOF
#!/bin/sh
printf '$c %s\n' "\$*" >> "$STUB_LOG"
EOF
  done
  chmod +x "$STAGE/bin"/*
  PATH="$STAGE/bin:$PATH"; export PATH STUB_LOG
}

run_flash() { # run_flash <answers-file> [args...]
  _answers="$1"; shift
  OUT_DIR="$STAGE/out" sh "$STAGE/flash-image.sh" "$@" < "$_answers" > "$STAGE/run.out" 2>&1
}

stage
assert_ok "--help exits 0" sh "$STAGE/flash-image.sh" --help
assert_fails "an unknown flag is rejected" sh "$STAGE/flash-image.sh" --bogus

# --- --image-only: build reuse + convert, no flash -------------------------------
stage
printf '\n' > "$STAGE/in"   # reuse the existing qcow2
assert_ok "--image-only exits 0" run_flash "$STAGE/in" --image-only
assert_contains "the existing image is reused" "$STAGE/run.out" 'Reuse it'
assert_contains_fixed "qemu-img converts qcow2 -> raw" "$STUB_LOG" 'qemu-img convert -O raw'
assert_contains "the raw image exists" "$STAGE/run.out" 'Raw image ready'
assert_not_contains "nothing is flashed in --image-only" "$STUB_LOG" 'dd '
assert_contains "--image-only says it stops before flashing" "$STAGE/run.out" 'stopping before the flash'

# --- happy path: reuse -> pick sdb -> confirm -> dd -> keep raw --------------------
stage
printf '\nsdb\nsdb\nn\n' > "$STAGE/in"
assert_ok "happy path exits 0" run_flash "$STAGE/in"
assert_contains "the removable disk is listed" "$STAGE/run.out" 'USBSTICK'
assert_contains_fixed "dd writes the raw image to /dev/sdb" "$STUB_LOG" 'dd if='
assert_contains_fixed "dd targets the picked disk" "$STUB_LOG" 'of=/dev/sdb'
assert_contains "the stick's partitions were unmounted first" "$STUB_LOG" 'umount /dev/sdb1'
assert_contains "completion instructions are printed" "$STAGE/run.out" 'Stick flashed'
assert_ok "answering n keeps the raw image" test -f "$STAGE/out/appliance.raw"

# --- the system disk is refused ------------------------------------------------------
stage
printf '\nsda\n' > "$STAGE/in"
assert_fails "picking the system disk aborts" run_flash "$STAGE/in"
assert_contains "the refusal names the running system" "$STAGE/run.out" 'hosts the running system'
assert_not_contains "dd never ran" "$STUB_LOG" 'dd if='

# --- an unknown disk is refused -------------------------------------------------------
stage
printf '\nsdz\n' > "$STAGE/in"
assert_fails "picking an unknown disk aborts" run_flash "$STAGE/in"
assert_not_contains "dd never ran" "$STUB_LOG" 'dd if='

# --- a mismatched confirmation stops before dd -----------------------------------------
stage
printf '\nsdb\nNOPE\n' > "$STAGE/in"
assert_fails "a wrong confirmation aborts" run_flash "$STAGE/in"
assert_contains "the abort says nothing was written" "$STAGE/run.out" 'nothing was written'
assert_not_contains "dd never ran" "$STUB_LOG" 'dd if='

# --- an empty disk answer aborts ---------------------------------------------------------
stage
printf '\n\n' > "$STAGE/in"
assert_fails "an empty disk answer aborts" run_flash "$STAGE/in"
assert_not_contains "dd never ran" "$STUB_LOG" 'dd if='

summary
