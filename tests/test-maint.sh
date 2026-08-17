#!/bin/sh
# tests/test-maint.sh — day-two maintenance tools: package MCS + SBOM (T-11) and
# the end-of-life secure erase (T-08). The destructive path is NEVER exercised —
# only the dry-run guard and the read-only SBOM path, which is the whole point of
# the guard.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== host/secure-erase.sh (guard) =="
new_sandbox
# Plant a fake VM disk; a DRY RUN (no CONFIRM) must NOT touch it.
: > "$SANDBOX/images/office.qcow2"
"$SANDBOX/src/host.sh" secure-erase --vms > "$SANDBOX/erase.out" 2>&1; rc=$?
assert_eq  "dry run (no CONFIRM) exits 0"                "0" "$rc"
assert_contains "it announces a DRY RUN"                 "$SANDBOX/erase.out" 'DRY RUN'
assert_contains "it only says what it WOULD erase"       "$SANDBOX/erase.out" 'WOULD'
if [ -f "$SANDBOX/images/office.qcow2" ]; then
  _g "a disk is NOT erased without CONFIRM=ERASE"
else
  _b "a disk is NOT erased without CONFIRM=ERASE"
fi
# No confirmation token -> it must never invoke a destructive verb.
assert_not_contains "no live shred/erase happened" "$STUB_LOG" 'cryptsetup erase'

echo
echo "== host/update-packages.sh (SBOM) =="
new_sandbox
"$SANDBOX/src/host.sh" update-packages --sbom-only > "$SANDBOX/pkg.out" 2>&1; rc=$?
assert_eq "sbom-only exits 0" "0" "$rc"
# It must produce a bill of materials with a host section. The path is fixed
# (/var/lib/appliance-sbom); grab the newest one this run just wrote.
_sbom="$(ls -1t /var/lib/appliance-sbom/sbom-*.txt 2>/dev/null | head -1 || true)"
if [ -n "$_sbom" ] && [ -f "$_sbom" ]; then
  _g "an SBOM file is written"
  assert_contains "the SBOM has a host section" "$_sbom" '## host'
else
  _b "an SBOM file is written"
fi

echo
echo "== setup.sh wiring =="
new_sandbox
"$SANDBOX/setup.sh" </dev/null > "$SANDBOX/menu.out" 2>&1
assert_contains "menu offers package update (step 9)" "$SANDBOX/menu.out" '9\) Update packages'
assert_contains "menu offers secure erase (step 10)"  "$SANDBOX/menu.out" '10\) Secure erase'
assert_contains "menu offers the file diode (step 11)" "$SANDBOX/menu.out" '11\) File diode'
# Step 11 dispatches to diode.sh in direct mode, forwarding args. With no DIODES
# configured (the harness default) it is a clean no-op — which proves the wiring.
"$SANDBOX/setup.sh" 11 --list > "$SANDBOX/diode-step.out" 2>&1
assert_contains "step 11 runs the diode script" "$SANDBOX/diode-step.out" 'No diodes configured'

summary
