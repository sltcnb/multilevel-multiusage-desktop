#!/bin/sh
# tests/test-watch.sh — host/isolation-watch, the continuous half of the
# isolation guarantee. The container is privileged, so every ruleset here is
# loaded into the REAL kernel and then really tampered with: a rule is deleted
# by handle, the whole table is flushed. The watch has to notice from the kernel
# state, not from anything a mock told it.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== host/isolation-watch =="
new_sandbox

STATUS=/run/appliance/isolation.status
AUDIT=/var/log/appliance-audit.log
WATCH="$SANDBOX/src/host.sh"

# Wipe the tmpfs state and the audit log — the state a freshly booted appliance
# would have.
reset_runtime() { rm -rf /run/appliance; rm -f "$AUDIT"; }

# Load a known-good isolation ruleset by running the real generator.
apply_isolation() {
  nft flush ruleset 2>/dev/null || true
  STUB_AGENT=down "$SANDBOX/src/environments.sh" isolate > "$SANDBOX/isolate.out" 2>&1
}

# Fields of the CONTRACT A line.
st_field() { cut -f"$1" "$STATUS" 2>/dev/null; }

# Delete exactly one inter-env DROP rule from the live kernel ruleset, by handle.
delete_drop_rule() {
  _h="$(nft -a list table inet appliance_isol 2>/dev/null \
        | grep "ip saddr $1 ip daddr $2 " | sed -n 's/.*# handle \([0-9]*\).*/\1/p' | head -1)"
  [ -n "$_h" ] && nft delete rule inet appliance_isol forward handle "$_h"
}

audit_lines() { [ -f "$AUDIT" ] && wc -l < "$AUDIT" | tr -d ' ' || echo 0; }

# --- isolate.sh wires the watch up -------------------------------------------
reset_runtime
apply_isolation
assert_contains "isolate.sh installs the recurring check" "$SANDBOX/isolate.out" 'Recurring isolation check installed'
if [ -f "$STATUS" ]; then
  _g "isolate.sh leaves a populated status file behind"
else
  _b "isolate.sh leaves a populated status file behind"
fi
assert_eq "isolate.sh still exits 0 when its own checks pass" 0 "$?" >/dev/null 2>&1
assert_contains "the crontab line runs the watch" /etc/crontabs/root 'isolation-watch --once'

# --- CONTRACT A format --------------------------------------------------------
reset_runtime
"$WATCH" isolation-watch --once > "$SANDBOX/ok.out" 2>&1
rc_ok=$?
assert_eq "an intact ruleset exits 0" 0 "$rc_ok"
assert_eq "STATE is OK" "OK" "$(st_field 1)"
assert_eq "the status file is exactly one line" 1 "$(wc -l < "$STATUS" | tr -d ' ')"
assert_eq "the line has exactly three TAB-separated fields" 3 "$(awk -F'\t' '{print NF}' "$STATUS")"
assert_mode "the status file is world-readable, root-written (0644)" 644 "$STATUS"
# EPOCH must be a plausible "now", not a literal or a leftover.
epoch="$(st_field 2)"
case "$epoch" in
  ''|*[!0-9]*) _b "EPOCH is a positive integer (got '$epoch')" ;;
  *) if [ "$(( $(date +%s) - epoch ))" -lt 120 ]; then
       _g "EPOCH is the current time"
     else _b "EPOCH is the current time (got $epoch)"; fi ;;
esac
assert_eq "DETAIL counts every ordered pair of the 3 envs" "6/6 pairs" "$(st_field 3)"

# --- one deleted DROP rule ----------------------------------------------------
# The single most likely real-world regression: a rule goes missing while the
# rest of the table looks perfectly healthy.
reset_runtime
apply_isolation
"$WATCH" isolation-watch --once >/dev/null 2>&1                      # establish OK as the prior state
delete_drop_rule 10.10.1.0/24 10.10.2.0/24
"$WATCH" isolation-watch --once > "$SANDBOX/broken.out" 2>&1
rc_broken=$?
assert_eq "a missing DROP rule exits non-zero" 1 "$rc_broken"
assert_eq "a missing DROP rule reads FAIL" "FAIL" "$(st_field 1)"
assert_contains "DETAIL names the pair that lost its fence" "$STATUS" 'missing office->development'
assert_contains "DETAIL still reports the tally" "$STATUS" '5/6 pairs'
assert_eq "the FAIL line is still one line" 1 "$(wc -l < "$STATUS" | tr -d ' ')"

# --- the whole table flushed --------------------------------------------------
# With no table there are no rules to look for, so a naive "count what's
# missing" loop finds nothing missing. That must NOT read as OK.
reset_runtime
apply_isolation
"$WATCH" isolation-watch --once >/dev/null 2>&1
nft flush ruleset
"$WATCH" isolation-watch --once > "$SANDBOX/flushed.out" 2>&1
rc_flushed=$?
assert_eq "a flushed ruleset exits non-zero" 1 "$rc_flushed"
assert_eq "a flushed ruleset reads FAIL, not a vacuous OK" "FAIL" "$(st_field 1)"
assert_contains "DETAIL says the table itself is gone" "$STATUS" 'appliance_isol is absent'

# --- audit: transitions only --------------------------------------------------
reset_runtime
apply_isolation                                       # isolate.sh runs the watch once
assert_eq "the first check of a boot logs one transition" 1 "$(audit_lines)"
assert_contains "the transition records the new and previous state" "$AUDIT" 'isolation-check state=OK prev=UNKNOWN'
assert_contains "the audit timestamp is ISO8601 UTC" "$AUDIT" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z '
assert_mode "the audit log is root-only (0600)" 600 "$AUDIT"

"$WATCH" isolation-watch --once >/dev/null 2>&1
"$WATCH" isolation-watch --once >/dev/null 2>&1
assert_eq "an unchanged state writes nothing (the log must not fill up)" 1 "$(audit_lines)"

delete_drop_rule 10.10.2.0/24 10.10.3.0/24
"$WATCH" isolation-watch --once >/dev/null 2>&1
assert_eq "a state change is logged" 2 "$(audit_lines)"
assert_contains "the FAIL transition names the missing pair" "$AUDIT" 'isolation-check state=FAIL prev=OK pairs=5/6 missing=development->administration'
"$WATCH" isolation-watch --once >/dev/null 2>&1
assert_eq "a repeated FAIL is not logged again" 2 "$(audit_lines)"

apply_isolation                                       # repairs the ruleset and re-checks
assert_eq "the recovery back to OK is logged" 3 "$(audit_lines)"
assert_contains "the recovery records where it came from" "$AUDIT" 'isolation-check state=OK prev=FAIL'
# CONTRACT B: values are single tokens — nothing that could hide a secret or
# break a parser on a space.
if awk 'NF>=3 { for (i=3;i<=NF;i++) if ($i !~ /^[^ =]+=[^ ]+$/) bad=1 } END { exit bad?1:0 }' "$AUDIT"; then
  _g "every audit value is a space-free key=value token"
else
  _b "every audit value is a space-free key=value token"
fi

# --- boot behaviour: /run is tmpfs, so the verdict cannot outlive a boot -------
# Simulate the reboot by removing the tmpfs directory, which is what a fresh
# /run gives us. A reader must find nothing (=> UNKNOWN), never last boot's OK.
apply_isolation
"$WATCH" isolation-watch --once >/dev/null 2>&1
assert_eq "before the reboot the file says OK" "OK" "$(st_field 1)"
rm -rf /run/appliance
if [ ! -e "$STATUS" ]; then
  _g "a fresh tmpfs leaves no status file — readers see UNKNOWN, not a stale OK"
else
  _b "a fresh tmpfs leaves no status file"
fi
rm -f "$AUDIT"
"$WATCH" isolation-watch --once >/dev/null 2>&1
assert_contains "the first check after a boot logs the UNKNOWN->OK transition" "$AUDIT" 'state=OK prev=UNKNOWN'

# --- a corrupt status file must not crash the reader --------------------------
mkdir -p /run/appliance
printf 'garbage without any tabs at all\n' > "$STATUS"
"$WATCH" isolation-watch --once > "$SANDBOX/corrupt.out" 2>&1
assert_eq "an unparsable status file is overwritten with a real verdict" "OK" "$(st_field 1)"
assert_contains "an unparsable previous state is treated as UNKNOWN" "$AUDIT" 'state=OK prev=UNKNOWN'

# --- concurrent runs -----------------------------------------------------------
reset_runtime
"$WATCH" isolation-watch --once >/dev/null 2>&1 &
"$WATCH" isolation-watch --once >/dev/null 2>&1 &
wait
assert_eq "two concurrent checks log the transition exactly once" 1 "$(audit_lines)"
assert_eq "and still leave a valid status behind" "OK" "$(st_field 1)"
if [ ! -d /run/appliance/isolation-watch.lock ]; then
  _g "the lock is released (a wedged lock would freeze the verdict forever)"
else
  _b "the lock is released"
fi

# --- a DISABLED env is still watched ------------------------------------------
# isolate.sh fences disabled envs on purpose (their VM and libvirt net keep
# running). A watch that only looked at enabled envs would report OK on exactly
# the configuration that fence protects.
new_sandbox
WATCH="$SANDBOX/src/host.sh"
cfg_set development_ENABLED 0
reset_runtime
apply_isolation
assert_eq "a disabled env still counts toward the expected pairs" "6/6 pairs" "$(st_field 3)"
delete_drop_rule 10.10.1.0/24 10.10.2.0/24            # office -> the DISABLED env
"$WATCH" isolation-watch --once >/dev/null 2>&1
rc_dis=$?
assert_eq "losing the fence around a disabled env is a FAIL" "FAIL" "$(st_field 1)"
assert_eq "and exits non-zero" 1 "$rc_dis"

# --- an empty environment model is UNKNOWN, never OK ---------------------------
new_sandbox
WATCH="$SANDBOX/src/host.sh"
cfg_set ENVS ""
reset_runtime
mkdir -p /run/appliance
"$WATCH" isolation-watch --once > "$SANDBOX/noenv.out" 2>&1
rc_noenv=$?
assert_eq "an empty ENVS reads UNKNOWN" "UNKNOWN" "$(st_field 1)"
assert_eq "an empty ENVS does not exit 0" 2 "$rc_noenv"

# --- timer installation is idempotent -----------------------------------------
new_sandbox
WATCH="$SANDBOX/src/host.sh"
rm -f /etc/crontabs/root
"$WATCH" isolation-watch --install-timer >/dev/null 2>&1
"$WATCH" isolation-watch --install-timer >/dev/null 2>&1
assert_eq "re-running the installer leaves exactly one crontab entry" \
  1 "$(grep -c 'isolation-watch' /etc/crontabs/root)"
assert_contains "the default interval is every minute" /etc/crontabs/root '^\* \* \* \* \* .*isolation-watch --once'
assert_contains "cron output is discarded (the status file is the channel)" /etc/crontabs/root '>/dev/null 2>&1$'
assert_mode "the root crontab stays 0600" 600 /etc/crontabs/root
assert_contains "crond is enabled at boot" "$STUB_LOG" 'rc-update add crond default'

cfg_set ISOLATION_WATCH_INTERVAL 300
"$WATCH" isolation-watch --install-timer >/dev/null 2>&1
assert_contains "a longer interval becomes a */N schedule" /etc/crontabs/root '^\*/5 \* \* \* \* .*isolation-watch'
assert_eq "changing the interval replaces the entry rather than adding one" \
  1 "$(grep -c 'isolation-watch' /etc/crontabs/root)"

cfg_set ISOLATION_WATCH 0
"$WATCH" isolation-watch --install-timer > "$SANDBOX/off.out" 2>&1
assert_eq "ISOLATION_WATCH=0 removes the entry" 0 "$(grep -c 'isolation-watch' /etc/crontabs/root)"
assert_contains "and says out loud what was given up" "$SANDBOX/off.out" 'NOT installed'

# --- systemd hosts get a real timer -------------------------------------------
# Run with a PATH that has no rc-update (the Debian development path). The
# container has no OpenRC of its own, so dropping the stub dir is enough.
new_sandbox
rm -f /etc/systemd/system/appliance-isolation-watch.*
mkdir -p "$SANDBOX/sdbin"
cp "$STUBS/systemctl" "$SANDBOX/sdbin/systemctl"
cfg_set ISOLATION_WATCH_INTERVAL 30
env PATH="$SANDBOX/sdbin:/usr/sbin:/usr/bin:/sbin:/bin" STUB_LOG="$SANDBOX/sd.log" \
  "$SANDBOX/src/host.sh" isolation-watch --install-timer > "$SANDBOX/sd.out" 2>&1
assert_contains "a systemd host gets a .timer unit" /etc/systemd/system/appliance-isolation-watch.timer 'OnUnitActiveSec=30s'
assert_contains "the timer drives a oneshot check" /etc/systemd/system/appliance-isolation-watch.service 'ExecStart=.*isolation-watch --once'
assert_contains "the timer is enabled" "$SANDBOX/sd.log" 'systemctl enable --now appliance-isolation-watch.timer'
assert_mode "units are 0644" 644 /etc/systemd/system/appliance-isolation-watch.timer

rm -f /etc/systemd/system/appliance-isolation-watch.*
nft flush ruleset 2>/dev/null || true
reset_runtime
summary
