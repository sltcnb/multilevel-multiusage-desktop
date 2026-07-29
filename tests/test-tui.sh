#!/bin/sh
# tests/test-tui.sh — the operator console (host/tui.sh) and setup-machine.sh's new
# launcher behaviour.
#
# Everything here runs in the FORCED TEXT FALLBACK (TUI_NO_DIALOG=1; the
# container has no dialog binary anyway) with piped input, which is exactly the
# "dialog missing / dumb terminal / stdin is a pipe" path that must never
# crash. The underlying step scripts (wifi/create/isolate/update/...) are
# replaced in the sandbox by marker stubs so the test proves the console
# dispatches to the RIGHT script without downloading gigabytes.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

export TUI_NO_DIALOG=1

# stub_script PATH MARKER — replace a sandbox script with one that just echoes
# its marker and arguments (which the console shows back in its result pane).
stub_script() {
  cat > "$1" <<EOF
#!/bin/sh
echo "$2 \$*"
EOF
  chmod +x "$1"
}

echo "== setup-machine.sh launcher =="
new_sandbox
printf '#!/bin/sh\necho TUI-EXECED\n' > "$SANDBOX/host/tui.sh"
chmod +x "$SANDBOX/host/tui.sh"
"$SANDBOX/setup-machine.sh" </dev/null > "$SANDBOX/launch.out" 2>&1
assert_contains "no arguments execs host/tui.sh" "$SANDBOX/launch.out" 'TUI-EXECED'
"$SANDBOX/setup-machine.sh" --menu </dev/null > "$SANDBOX/oldmenu.out" 2>&1
assert_contains "--menu still shows the classic numbered menu" "$SANDBOX/oldmenu.out" '3\) Create the VMs'
"$SANDBOX/setup-machine.sh" -h > "$SANDBOX/help.out" 2>&1
assert_contains "-h documents the console" "$SANDBOX/help.out" 'host/tui\.sh'
assert_contains "-h documents --menu" "$SANDBOX/help.out" 'classic numbered text menu'
echo
echo "== host/tui.sh: main loop (fallback) =="
new_sandbox
export AUDIT_LOG="$SANDBOX/audit.log"
printf 'q\n' | "$SANDBOX/host/tui.sh" > "$SANDBOX/q.out" 2>&1
assert_eq "'q' exits 0" 0 "$?"
assert_contains "the main menu renders" "$SANDBOX/q.out" 'Status dashboard'
assert_contains "the guided setup is offered" "$SANDBOX/q.out" 'Guided first setup'

printf 'zzz\nq\n' | "$SANDBOX/host/tui.sh" > "$SANDBOX/bad.out" 2>&1
assert_eq "an invalid choice still exits 0" 0 "$?"
assert_contains "an invalid choice is rejected and re-prompts" "$SANDBOX/bad.out" 'Invalid choice'

echo
echo "== host/tui.sh: status dashboard (CONTRACT A) =="
new_sandbox
export AUDIT_LOG="$SANDBOX/audit.log"
# Missing status file: UNKNOWN, never a crash.
APPLIANCE_STATUS_FILE="$SANDBOX/no-such.status" \
  sh -c "printf '1\n\nn\nq\n' | '$SANDBOX/host/tui.sh'" > "$SANDBOX/d-missing.out" 2>&1
assert_eq "dashboard with a missing status file exits 0" 0 "$?"
assert_contains "missing status file reads as UNKNOWN" "$SANDBOX/d-missing.out" 'UNKNOWN'
assert_contains "and says why" "$SANDBOX/d-missing.out" 'has not run'
assert_contains "the VM list is still queried" "$STUB_LOG" 'virsh list'
assert_contains "the uplink is shown" "$SANDBOX/d-missing.out" 'default via 192\.168\.1\.1'

# Garbage status file: also UNKNOWN, never a crash.
printf 'this is not a verdict\n' > "$SANDBOX/garbage.status"
APPLIANCE_STATUS_FILE="$SANDBOX/garbage.status" \
  sh -c "printf '1\n\nn\nq\n' | '$SANDBOX/host/tui.sh'" > "$SANDBOX/d-garbage.out" 2>&1
assert_eq "dashboard with a garbage status file exits 0" 0 "$?"
assert_contains "garbage status file reads as UNKNOWN" "$SANDBOX/d-garbage.out" 'UNKNOWN'
assert_contains "and says the file is unreadable" "$SANDBOX/d-garbage.out" 'unreadable or garbage'

# A real OK verdict is shown in plain language, and the offered refresh
# dispatches to host/isolation-watch.sh --once.
printf 'OK\t1720000000\t6/6 pairs\n' > "$SANDBOX/ok.status"
stub_script "$SANDBOX/host/isolation-watch.sh" STUB-WATCH
APPLIANCE_STATUS_FILE="$SANDBOX/ok.status" \
  sh -c "printf '1\n\ny\n\n\nq\n' | '$SANDBOX/host/tui.sh'" > "$SANDBOX/d-ok.out" 2>&1
assert_eq "dashboard with an OK verdict exits 0" 0 "$?"
assert_contains "the OK verdict is explained plainly" "$SANDBOX/d-ok.out" 'verified in place'
assert_contains "the verdict detail is shown" "$SANDBOX/d-ok.out" '6/6 pairs'
assert_contains "refresh re-runs isolation-watch.sh --once" "$SANDBOX/d-ok.out" 'STUB-WATCH --once'

echo
echo "== host/tui.sh: guided first setup =="
new_sandbox
export AUDIT_LOG="$SANDBOX/audit.log"
stub_script "$SANDBOX/host/wifi.sh" STUB-WIFI
stub_script "$SANDBOX/environments/create.sh" STUB-CREATE
stub_script "$SANDBOX/environments/isolate.sh" STUB-ISOLATE
# 2=guided, then per step: confirm and acknowledge each result pane.
printf '2\n\ny\n\n\n\ny\ny\n\n\ny\n\n\n\nq\n' | "$SANDBOX/host/tui.sh" > "$SANDBOX/guided.out" 2>&1
assert_eq "guided setup exits 0" 0 "$?"
assert_contains "step 1 runs host/wifi.sh" "$SANDBOX/guided.out" 'STUB-WIFI'
assert_contains "step 3 runs environments/create.sh" "$SANDBOX/guided.out" 'STUB-CREATE'
assert_contains "step 4 runs environments/isolate.sh" "$SANDBOX/guided.out" 'STUB-ISOLATE'
assert_contains "the create step warns about the download" "$SANDBOX/guided.out" 'GIGABYTES'
assert_contains_fixed "the portal step explains Super+p" "$SANDBOX/guided.out" 'Super+p'
assert_contains "the actions are audited" "$AUDIT_LOG" 'tui action=wifi'
assert_contains "the result is audited too" "$AUDIT_LOG" 'result=OK'

echo
echo "== host/tui.sh: operations — update check =="
new_sandbox
export AUDIT_LOG="$SANDBOX/audit.log"
stub_script "$SANDBOX/host/update.sh" STUB-UPDATE
# 3=operations, 6=check updates, y=confirm, two result panes, q=back, q=exit.
printf '3\n6\ny\n\n\nq\nq\n' | "$SANDBOX/host/tui.sh" > "$SANDBOX/ops.out" 2>&1
assert_eq "operations flow exits 0" 0 "$?"
assert_contains "update check dispatches host/update.sh --check" "$SANDBOX/ops.out" 'STUB-UPDATE --check'
assert_contains "the update check is audited" "$AUDIT_LOG" 'action=update-check'

summary
