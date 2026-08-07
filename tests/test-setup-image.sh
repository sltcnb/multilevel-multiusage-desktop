#!/bin/sh
# tests/test-setup-image.sh — the first-run image wizard (setup-image.sh).
#
# The wizard writes config.env NEXT TO ITSELF, so instead of the harness
# sandbox (which does not copy root-level scripts) each scenario stages
# setup-image.sh + src/lib/common.sh in a throwaway mktemp dir and runs it there.
# SKIP_PREFLIGHT=1 keeps the docker/disk host checks out of the tests, so this
# file needs NO docker and NO stubs.
set -u
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== setup-image.sh =="

stage() {
  STAGE="$(mktemp -d)"
  mkdir -p "$STAGE/src/lib"
  cp "$REPO_ROOT/src/lib/common.sh" "$STAGE/src/lib/common.sh"
  cp "$REPO_ROOT/setup-image.sh" "$STAGE/setup-image.sh"
  cp "$REPO_ROOT/config.env.example" "$STAGE/config.env.example"
}

# --- --help ---------------------------------------------------------------------
stage
assert_ok "--help exits 0" sh "$STAGE/setup-image.sh" --help
sh "$STAGE/setup-image.sh" --help > "$STAGE/help.out" 2>&1
assert_contains "--help documents --defaults" "$STAGE/help.out" '\-\-defaults'
assert_fails "an unknown flag is rejected" sh "$STAGE/setup-image.sh" --bogus

# --- --defaults -------------------------------------------------------------------
stage
SKIP_PREFLIGHT=1 sh "$STAGE/setup-image.sh" --defaults > "$STAGE/def.out" 2>&1
assert_ok "generated config.env is valid shell" sh -n "$STAGE/config.env"
assert_mode "generated config.env is 0600" 600 "$STAGE/config.env"
assert_contains "defaults write the fixed env list" "$STAGE/config.env" '^ENVS="office development administration"$'
assert_contains "defaults enable office on Ubuntu/GNOME" "$STAGE/config.env" '^office_OS="ubuntu"$'
assert_contains "defaults write per-env egress" "$STAGE/config.env" '^administration_EGRESS_MODE="all"$'
assert_contains "defaults write the guest user" "$STAGE/config.env" '^GUEST_USER="operator"$'
assert_contains "defaults plant the well-known placeholder password (CI-only)" "$STAGE/config.env" '^HOST_ROOT_PASSWORD="changeme"$'
assert_contains "defaults write the security toggles" "$STAGE/config.env" '^TRUST_BAR=1$'
assert_contains "defaults write the build options" "$STAGE/config.env" '^ALPINE_BRANCH="v3.22"$'
assert_contains "defaults write IMG_SIZE" "$STAGE/config.env" '^IMG_SIZE="4G"$'
# <OS>_IMG_GPG_FPR is tri-state in create.sh: an empty pin must OMIT the line
# (writing ="" is a hard refusal there, not "feature off").
assert_not_contains "empty GPG pins are omitted, not written empty" "$STAGE/config.env" 'IMG_GPG_FPR'

# --- the generated config is COMPLETE ----------------------------------------------
# Appliance scripts dereference config keys under `set -u`; a key the wizard
# omits crashes first boot (IMAGES_DIR did, on real hardware). Every
# uncommented KEY=... line in config.env.example must be carried over.
_missing=""
while IFS= read -r _line; do
  _key="${_line%%=*}"
  grep -q "^$_key=" "$STAGE/config.env" || _missing="$_missing $_key"
done <<EOF
$(grep -E '^[A-Za-z_][A-Za-z_0-9]*=' "$REPO_ROOT/config.env.example")
EOF
assert_eq "every uncommented example key is carried into the generated config" "" "$_missing"
assert_ok "the carried-over config is still valid shell" sh -n "$STAGE/config.env"
assert_contains "carried keys keep their example default (IMAGES_DIR)" "$STAGE/config.env" '^IMAGES_DIR="/var/lib/libvirt/images"$'
assert_not_contains "commented-out opt-in keys stay out (UBUNTU_IMG_GPG_FPR)" "$STAGE/config.env" '^UBUNTU_IMG_GPG_FPR='
assert_contains "uncommented-but-empty pins are carried, inert (update stays fail-closed)" "$STAGE/config.env" '^UPDATE_GPG_FPR=""$'

# --- piped answers ------------------------------------------------------------------
# First three answers drive office; the two passwords are REQUIRED (no blanks
# there); everything after takes the defaults from blank lines.
stage
( printf 'y\ndebian\nxfce4\n\n\n\n\n\n\n\nguestpw123\nrootpw123\n'; yes '' ) | SKIP_PREFLIGHT=1 sh "$STAGE/setup-image.sh" > "$STAGE/piped.out" 2>&1
assert_ok "piped config.env is valid shell" sh -n "$STAGE/config.env"
assert_contains "a piped answer wins: office_OS=debian" "$STAGE/config.env" '^office_OS="debian"$'
assert_contains "a piped answer wins: office_DE=xfce4" "$STAGE/config.env" '^office_DE="xfce4"$'
assert_contains "the required guest password is taken from the pipe" "$STAGE/config.env" '^GUEST_PASSWORD="guestpw123"$'
assert_contains "the required host root password is taken from the pipe" "$STAGE/config.env" '^HOST_ROOT_PASSWORD="rootpw123"$'
assert_contains "blank answers keep the defaults (development stays arch)" "$STAGE/config.env" '^development_OS="arch"$'
assert_contains "the office Intune warning is shown for a non-Ubuntu office" "$STAGE/piped.out" 'Intune'

# --- passwords are REQUIRED: blank answers cannot skip them ----------------------------
stage
( yes '' ) | SKIP_PREFLIGHT=1 sh "$STAGE/setup-image.sh" > "$STAGE/nopw.out" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ]; then _g "all-blank input aborts at the required password"; PASS=$((PASS+1)); else
  _b "all-blank input aborts at the required password"; fi
assert_contains "the abort says a value is required" "$STAGE/nopw.out" 'required'
assert_fails "and no config.env is written" test -f "$STAGE/config.env"

# --- existing config.env: back up, never clobber --------------------------------------
stage
printf '# ORIGINAL - DO NOT TOUCH\nGUEST_USER="original"\n' > "$STAGE/config.env"
# The existing config has no passwords, so they must be answered (positions 11-12).
( printf '\n%.0s' 1 2 3 4 5 6 7 8 9 10; printf 'guestpw\nrootpw\n'; yes '' ) | SKIP_PREFLIGHT=1 sh "$STAGE/setup-image.sh" > "$STAGE/bak.out" 2>&1
_bak="$(ls "$STAGE"/config.env.bak-* 2>/dev/null | head -1)"
if [ -n "$_bak" ]; then _g "an existing config.env is backed up before writing"; PASS=$((PASS+1)); else
  _b "an existing config.env is backed up before writing"; fi
assert_contains_fixed "the backup holds the ORIGINAL content" "$_bak" 'ORIGINAL - DO NOT TOUCH'
assert_contains "the new config.env replaces it" "$STAGE/config.env" '^ENVS='
assert_not_contains "the original marker is gone from the live config" "$STAGE/config.env" 'ORIGINAL'

# --- existing config.env: refusing overwrite leaves it byte-for-byte untouched ---------
stage
printf '# ORIGINAL - DO NOT TOUCH\nGUEST_USER="original"\n' > "$STAGE/config.env"
# 10 blanks cover the questions before the two REQUIRED passwords (positions
# 11-12, the staged config has none); 16 more blanks cover the rest and the
# summary confirmation; the last line answers 'n' to "back it up and replace it?".
{ printf '\n%.0s' 1 2 3 4 5 6 7 8 9 10
  printf 'guestpw\nrootpw\n'
  printf '\n%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
  printf 'n\n'; } | SKIP_PREFLIGHT=1 sh "$STAGE/setup-image.sh" > "$STAGE/ref.out" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ]; then _g "refusing overwrite aborts (non-zero exit)"; PASS=$((PASS+1)); else
  _b "refusing overwrite aborts (non-zero exit)"; fi
assert_contains_fixed "the old file is untouched" "$STAGE/config.env" 'ORIGINAL - DO NOT TOUCH'
assert_not_contains "no new config was written over it" "$STAGE/config.env" '^ENVS='
if ls "$STAGE"/config.env.bak-* >/dev/null 2>&1; then
  _b "no backup is created when the operator refuses"; else
  _g "no backup is created when the operator refuses"; PASS=$((PASS+1)); fi

# --- Ctrl+C: never a half-written config.env --------------------------------------------
stage
printf '# ORIGINAL - DO NOT TOUCH\nGUEST_USER="original"\n' > "$STAGE/config.env"
# A fifo held open read-write (fd 9) keeps stdin open with no data, so the
# wizard parks on its first read until we interrupt it.
# NOTE the signal: POSIX makes a non-interactive shell start ASYNC commands
# with SIGINT/SIGQUIT ignored, and a signal ignored at entry cannot be trapped
# — so a backgrounded test wizard could never see Ctrl+C. SIGTERM takes the
# SAME trap handler (trap on_int INT TERM) and keeps its default disposition,
# so it exercises the identical interrupt path.
mkfifo "$STAGE/in"
exec 9<>"$STAGE/in"
SKIP_PREFLIGHT=1 sh "$STAGE/setup-image.sh" <"$STAGE/in" >"$STAGE/sig.out" 2>&1 &
_sig_pid=$!
sleep 2
kill -TERM "$_sig_pid"
wait "$_sig_pid"
_sig_rc=$?
exec 9>&-
assert_eq "the interrupt handler exits 130" "130" "$_sig_rc"
assert_contains "the interrupt gets a friendly message" "$STAGE/sig.out" 'Interrupted'
assert_contains_fixed "the pre-existing config.env is untouched" "$STAGE/config.env" 'ORIGINAL - DO NOT TOUCH'
assert_not_contains "and certainly not half-written" "$STAGE/config.env" '^ENVS='
if ls "$STAGE"/config.env.tmp.* >/dev/null 2>&1; then
  _b "no temp file is left behind after an interrupt"; else
  _g "no temp file is left behind after an interrupt"; PASS=$((PASS+1)); fi

# Interrupt on a FRESH dir: no config.env may appear at all.
stage
mkfifo "$STAGE/in"
exec 9<>"$STAGE/in"
SKIP_PREFLIGHT=1 sh "$STAGE/setup-image.sh" <"$STAGE/in" >"$STAGE/sig2.out" 2>&1 &
_sig_pid=$!
sleep 2
kill -TERM "$_sig_pid"
wait "$_sig_pid"
exec 9>&-
if [ -e "$STAGE/config.env" ]; then
  _b "an interrupt before the write creates no config.env"; else
  _g "an interrupt before the write creates no config.env"; PASS=$((PASS+1)); fi

summary
