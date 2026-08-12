#!/bin/sh
# tests/test-diode.sh — environments/diode.sh, the ANSSI-PA-114 §3.18 file diode.
# The virsh stub gives each "up" guest a real filesystem under
# $STUB_STATE/gfs-<domain>/, and emulates the guest-file API + the ls/mkdir/rm/
# test guest-exec commands the diode uses, so a file placed in a source guest's
# outbox really does travel — mediated, hashed and logged — into the destination
# guest's inbox. That makes these assertions about real transfer behaviour, not
# a mock of it.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== environments/diode.sh (PA-114 §3.18) =="

# Guest filesystem helpers (operate on the fake FS the virsh stub serves).
gput() { # env guest-abs-path content
  f="$STUB_STATE/gfs-$1$2"; mkdir -p "$(dirname "$f")"; printf '%s' "$3" > "$f"; }
gpath() { printf '%s/gfs-%s%s' "$STUB_STATE" "$1" "$2"; }
OUT="/home/operator/diode-out"; IN="/home/operator/diode-in"

configure_diodes() {
  cfg_set DIODES "administration>development administration>office development>office"
}

# --- happy path: a queued file is delivered, hashed, logged, source cleared ----
new_sandbox
configure_diodes
gput administration "$OUT/development/report.txt" "hello-diode-payload"
AUDIT_LOG="$SANDBOX/audit.log" "$SANDBOX/environments/diode.sh" --yes > "$SANDBOX/run.out" 2>&1
delivered="$(gpath development "$IN/administration/report.txt")"
assert_ok "file delivered into the destination guest inbox" test -f "$delivered"
if [ -f "$delivered" ]; then
  assert_eq "delivered bytes are identical to the source" "hello-diode-payload" "$(cat "$delivered")"
fi
assert_ok "the source copy is removed after delivery" sh -c "[ ! -e '$(gpath administration "$OUT/development/report.txt")' ]"
assert_contains "the transfer is logged with the direction" "$SANDBOX/audit.log" 'diode-transfer src=administration dst=development'
assert_contains "the transfer log records a sha256" "$SANDBOX/audit.log" 'sha256=[0-9a-f]{64}'
assert_contains "the transfer log records the decision" "$SANDBOX/audit.log" 'decision=delivered'
# The real sha256 of the payload, so we know the logged hash is the file's hash.
want_hash="$(printf '%s' "hello-diode-payload" | sha256sum | awk '{print $1}')"
assert_contains "the logged hash is the payload's actual hash" "$SANDBOX/audit.log" "sha256=$want_hash"

# --- unidirectional: the reverse pair is NOT configured, so nothing flows back -
# A file dropped in development's outbox FOR administration must not move: only
# the SRC>DST pairs in $DIODES are diodes (§3.18.2).
new_sandbox
configure_diodes
gput development "$OUT/administration/leak.txt" "should-not-move"
AUDIT_LOG="$SANDBOX/audit.log" "$SANDBOX/environments/diode.sh" --yes > "$SANDBOX/rev.out" 2>&1
assert_ok "an unconfigured reverse direction delivers nothing" sh -c "[ ! -e '$(gpath administration "$IN/development/leak.txt")' ]"
assert_ok "the reverse-direction source file is left untouched" test -f "$(gpath development "$OUT/administration/leak.txt")"

# --- list mode: reports what is pending but transfers nothing -----------------
new_sandbox
configure_diodes
gput administration "$OUT/office/memo.txt" "peek-only"
AUDIT_LOG="$SANDBOX/audit.log" "$SANDBOX/environments/diode.sh" --list > "$SANDBOX/list.out" 2>&1
assert_contains "list mode names the pending file" "$SANDBOX/list.out" 'memo.txt'
assert_ok "list mode transfers nothing" sh -c "[ ! -e '$(gpath office "$IN/administration/memo.txt")' ]"
assert_ok "list mode leaves the source in place" test -f "$(gpath administration "$OUT/office/memo.txt")"
assert_not_contains "list mode logs no delivery" "$SANDBOX/audit.log" 'decision=delivered'

# --- an unsafe filename is refused and logged, never delivered ----------------
new_sandbox
configure_diodes
gput administration "$OUT/development/bad name.txt" "sneaky"
AUDIT_LOG="$SANDBOX/audit.log" "$SANDBOX/environments/diode.sh" --yes > "$SANDBOX/unsafe.out" 2>&1
assert_contains "an unsafe filename is refused" "$SANDBOX/audit.log" 'decision=refused reason=unsafe-name'
assert_ok "the unsafe file is not delivered" sh -c "[ ! -e '$(gpath development "$IN/administration/bad name.txt")' ]"

# --- the size cap refuses an oversized file -----------------------------------
new_sandbox
configure_diodes
cfg_set DIODE_MAX_BYTES 8
gput administration "$OUT/development/big.bin" "this is definitely more than eight bytes"
AUDIT_LOG="$SANDBOX/audit.log" "$SANDBOX/environments/diode.sh" --yes > "$SANDBOX/big.out" 2>&1
assert_contains "an oversized file is refused" "$SANDBOX/audit.log" 'decision=refused reason=too-big'
assert_ok "the oversized file is not delivered" sh -c "[ ! -e '$(gpath development "$IN/administration/big.bin")' ]"

# --- §3.18.6 content vetting: a deny-list hit refuses the file -----------------
new_sandbox
configure_diodes
cfg_set DIODE_SCAN 1
cfg_set DIODE_SCAN_DENYLIST "TOPSECRET"
gput administration "$OUT/development/doc.txt" "contains TOPSECRET marker"
AUDIT_LOG="$SANDBOX/audit.log" "$SANDBOX/environments/diode.sh" --yes > "$SANDBOX/scan.out" 2>&1
assert_contains "a deny-listed file is refused with the reason" "$SANDBOX/audit.log" 'decision=refused reason=denylist:TOPSECRET'
assert_ok "the deny-listed file is not delivered" sh -c "[ ! -e '$(gpath development "$IN/administration/doc.txt")' ]"

# --- a --pair that is not in DIODES is refused (fail closed) -------------------
new_sandbox
configure_diodes
assert_fails "an unlisted --pair is refused as unauthorized" \
  "$SANDBOX/environments/diode.sh" --pair "office>administration" --yes

# --- a malformed diode entry fails loudly, not silently -----------------------
new_sandbox
cfg_set DIODES "administration>administration"
assert_fails "a same-source-and-destination diode is rejected" \
  "$SANDBOX/environments/diode.sh" --yes

# --- no diodes configured: a clean no-op (the PA-114 default) ------------------
new_sandbox
cfg_set DIODES ""
AUDIT_LOG="$SANDBOX/audit.log" "$SANDBOX/environments/diode.sh" --yes > "$SANDBOX/none.out" 2>&1
assert_eq "with no diodes configured the script is a clean no-op" 0 "$?"
assert_contains "it says inter-domain exchange stays blocked" "$SANDBOX/none.out" 'blocked, which is the PA-114 default'

summary
