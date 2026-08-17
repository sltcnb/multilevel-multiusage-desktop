#!/bin/sh
# tests/test-compliance.sh — the post-install conformity gate (T-17 / SO-12).
# A read-only verifier must, on a machine where the provisioning steps did NOT
# take effect, say so plainly and exit non-zero so a boot hook / CI can refuse to
# put the machine into service. The sandbox is exactly that machine: no isolation
# table is loaded and the stub domains have no autostart, so every required check
# fails by construction — which is what makes the failure path deterministic.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== host/compliance-check.sh =="
new_sandbox

# Unprovisioned host: enabled envs have no domains, no appliance_isol table.
"$SANDBOX/src/host.sh" compliance-check > "$SANDBOX/comp.out" 2>&1; rc=$?

if [ "$rc" -ne 0 ]; then _g "exits non-zero when the machine is not compliant"; else
  _b "exits non-zero when the machine is not compliant"; sed 's/^/        /' "$SANDBOX/comp.out"; fi
assert_contains "prints a NON-COMPLIANT verdict"            "$SANDBOX/comp.out" 'NON-COMPLIANT'
assert_contains "names the missing isolation table"        "$SANDBOX/comp.out" 'appliance_isol'
assert_contains "flags an enabled env with no domain"      "$SANDBOX/comp.out" 'no libvirt domain'
# It must publish a machine-readable verdict, not only print one.
if [ -f /run/appliance/compliance.status ]; then
  assert_contains "publishes a tmpfs verdict line" /run/appliance/compliance.status 'NON-COMPLIANT'
else
  _b "publishes a tmpfs verdict line"
fi

# --gate drops a boot-blocking marker on failure ...
"$SANDBOX/src/host.sh" compliance-check --gate > "$SANDBOX/comp-gate.out" 2>&1 || true
if [ -f /run/appliance/NONCOMPLIANT ]; then _g "--gate drops the boot-block marker on failure"; else
  _b "--gate drops the boot-block marker on failure"; fi

# The operator menu offers it as step 8.
"$SANDBOX/setup.sh" </dev/null > "$SANDBOX/menu.out" 2>&1
assert_contains "the setup menu offers the compliance check (step 8)" "$SANDBOX/menu.out" '8\) Compliance check'
assert_contains "running step 8 dispatches to compliance-check.sh"    "$SANDBOX/menu.out" 'compliance-check.sh'

# Read-only: it must not attempt any state-changing virsh verb.
assert_not_contains "the check never mutates a domain" "$STUB_LOG" 'virsh (define|start|destroy|undefine|attach-device|detach-device)'

# Clean up the tmpfs marker so a later test run starts from a known state.
rm -f /run/appliance/NONCOMPLIANT 2>/dev/null || true

summary
