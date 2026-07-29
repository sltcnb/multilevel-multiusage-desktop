#!/bin/sh
# tests/test-audit.sh — the audit trail (CONTRACT B): the on-disk line format,
# the permission model that keeps a 0600 root log writable by an unprivileged
# desktop, rotation, and the events the host actually records.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

# common.sh derives APP_ROOT from $0's parent, so drive it through a script that
# lives one level down, exactly like the real callers. `set -eu` in the probe is
# the point of half these tests: audit_event must never abort its caller, so the
# probe reports on stderr that it survived the call.
mk_probe() {
  cat > "$SANDBOX/host/probe-audit.sh" <<'EOF'
#!/bin/sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
"$@"
echo "CALLER-CONTINUED" >&2
EOF
  chmod +x "$SANDBOX/host/probe-audit.sh"
}
probe() { "$SANDBOX/host/probe-audit.sh" "$@"; }

# Keep the log inside the sandbox: the suite runs as root in a container, where
# the real /var/log path would leak state between test files.
audit_paths() {
  AL="$SANDBOX/audit.log"; ASP="$SANDBOX/audit.d"
  AUDIT_LOG="$AL"; AUDIT_SPOOL="$ASP"; AUDIT_MAX_BYTES=262144
  export AUDIT_LOG AUDIT_SPOOL AUDIT_MAX_BYTES
}

echo "== CONTRACT B: one event, one line =="
new_sandbox; mk_probe; audit_paths
probe audit_event env-switch to=office idx=1 2>/dev/null
assert_eq "one call writes exactly one line" 1 "$(wc -l < "$AL" | tr -d ' ')"
assert_contains "the line is <ISO8601-UTC> <event> <k=v>..." "$AL" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z env-switch to=office idx=1$'

# Parse the line back the way a reader would, rather than only regex-matching it.
# shellcheck disable=SC2046  # deliberate word splitting: that IS the format
set -- $(cat "$AL")
assert_eq "it parses into 4 whitespace-separated fields" 4 "$#"
ts="$1"; ev="$2"; shift 2
assert_eq "the timestamp is today, in UTC" "$(date -u +%Y-%m-%d)" "${ts%T*}"
case "$ts" in *Z) _g "the timestamp is Zulu-suffixed" ;; *) _b "the timestamp is Zulu-suffixed" ;; esac
assert_eq "the event name comes second" "env-switch" "$ev"
bad=""
for f in "$@"; do case "$f" in *=*) ;; *) bad="$bad $f" ;; esac; done
assert_eq "every remaining field is key=value" "" "$bad"

# CONTRACT B lists the event names in use; they must all survive the writer.
: > "$AL"
for e in env-switch usb-route portal-login update isolation-check; do
  probe audit_event "$e" k=v 2>/dev/null
done
assert_eq "all five contract event names are written" 5 "$(grep -c ' k=v$' "$AL")"

echo
echo "== permissions =="
new_sandbox; mk_probe; audit_paths
probe audit_event update result=ok 2>/dev/null
assert_mode "the log is created 0600 (kiosk must never read it)" 600 "$AL"

# An operator who deliberately loosened the log (a log shipper's group, say)
# must not have it silently changed under them — and we must never widen it.
new_sandbox; mk_probe; audit_paths
( umask 077; : > "$AL" ); chmod 640 "$AL"
probe audit_event update result=ok 2>/dev/null
assert_mode "an existing log keeps the mode it had" 640 "$AL"
assert_contains "and is still appended to" "$AL" 'update result=ok'

echo
echo "== values can never break the line format =="
new_sandbox; mk_probe; audit_paths
probe audit_event usb-route "model=Yubico YubiKey OTP" env=office 2>/dev/null
assert_eq "a value containing spaces still writes one line" 1 "$(wc -l < "$AL" | tr -d ' ')"
assert_contains "the spaces are folded into the value" "$AL" 'model=Yubico_YubiKey_OTP env=office$'
assert_not_contains "no field is left containing a raw space" "$AL" 'model=Yubico YubiKey'
# A newline in a value would forge a whole extra event, which is the worst thing
# an audit log can do.
: > "$AL"
probe audit_event usb-route "note=$(printf 'a\nb\tc')" 2>/dev/null
assert_eq "an embedded newline cannot forge a second event" 1 "$(wc -l < "$AL" | tr -d ' ')"
assert_contains "the newline is folded too" "$AL" 'note=a_b_c$'
: > "$AL"
probe audit_event 'usb route' 'k=v v' 2>/dev/null
assert_eq "even a spaced EVENT name stays one line" 1 "$(wc -l < "$AL" | tr -d ' ')"
assert_contains "the event name is folded, not split" "$AL" ' usb_route k=v_v$'

echo
echo "== an unwritable log must not abort the caller =="
new_sandbox; mk_probe
: > "$SANDBOX/notadir"                       # a FILE where the log's parent must be
AUDIT_LOG="$SANDBOX/notadir/audit.log"; AUDIT_SPOOL="$SANDBOX/notadir/spool"
export AUDIT_LOG AUDIT_SPOOL
assert_ok "audit_event returns 0 when the log cannot be created" \
  "$SANDBOX/host/probe-audit.sh" audit_event usb-route env=office
err="$("$SANDBOX/host/probe-audit.sh" audit_event usb-route env=office 2>&1 >/dev/null || true)"
case "$err" in
  *CALLER-CONTINUED*) _g "a set -e caller carries on past a failed audit write" ;;
  *) _b "a set -e caller carries on past a failed audit write"; printf '        got: %s\n' "$err" ;;
esac
case "$err" in
  *audit*) _g "and the failure is at least reported" ;;
  *) _b "and the failure is at least reported" ;;
esac
assert_ok "audit_tail on a missing log is not an error either" \
  "$SANDBOX/host/probe-audit.sh" audit_tail 5

echo
echo "== rotation keeps the appliance disk bounded =="
new_sandbox; mk_probe; audit_paths
AUDIT_MAX_BYTES=200; export AUDIT_MAX_BYTES
i=0
while [ "$i" -lt 12 ]; do i=$((i+1)); probe audit_event env-switch "to=office" "idx=$i" 2>/dev/null; done
if [ -f "$AL.1" ]; then _g "the log rotates at the threshold"; else _b "the log rotates at the threshold"; fi
assert_mode "the rotated generation is 0600 too" 600 "$AL.1"
sz="$(wc -c < "$AL" | tr -d ' ')"
if [ "$sz" -lt 300 ]; then _g "the live log stays under the threshold (+one event)"
else _b "the live log stays under the threshold (+one event)"; printf '        size: %s\n' "$sz"; fi
assert_contains "the most recent event is in the live log" "$AL" 'idx=12$'
assert_contains "audit_tail spans the rotated generation" \
  "$(probe audit_tail 40 > "$SANDBOX/tail.out" 2>/dev/null; echo "$SANDBOX/tail.out")" 'idx=12$'
if [ "$(wc -l < "$SANDBOX/tail.out" | tr -d ' ')" -gt "$(wc -l < "$AL" | tr -d ' ')" ]; then
  _g "audit_tail shows more history than the live log alone"
else _b "audit_tail shows more history than the live log alone"; fi

echo
echo "== host/usb-to-vm.sh records where the peripheral went =="
new_sandbox; mk_probe; audit_paths
touch "$SANDBOX/stub-state/dom-office" "$SANDBOX/stub-state/dom-development" "$SANDBOX/stub-state/dom-administration"
printf '2\n' | "$SANDBOX/host/usb-to-vm.sh" > "$SANDBOX/usb.out" 2>&1
assert_contains "the route is audited with vendor, product and env" "$AL" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z usb-route vendor=1050 product=0407 env=development'
# Compartmentalisation is the control being evidenced: the record must also say
# which environments the device was taken away from.
assert_contains "and with the environments it was withdrawn from" "$AL" \
  'detached=office,administration result=attached'
assert_eq "one route is one line" 1 "$(wc -l < "$AL" | tr -d ' ')"

# A rejected choice routes nothing, so it must audit nothing.
new_sandbox; mk_probe; audit_paths
touch "$SANDBOX/stub-state/dom-office"
printf 'x\n' | "$SANDBOX/host/usb-to-vm.sh" > /dev/null 2>&1
if [ -s "$AL" ]; then _b "an invalid choice records no route"; else _g "an invalid choice records no route"; fi

echo
echo "== the kiosk user contributes events without reading the log =="
new_sandbox; mk_probe; audit_paths
probe audit_init 2>/dev/null
assert_mode "the spool is root-owned 1733: create-only, unlistable, sticky" 1733 "$ASP"
if id kiosk >/dev/null 2>&1; then
  chmod -R a+rX "$SANDBOX" 2>/dev/null || true
  chmod 600 "$AL" 2>/dev/null || true
  kuid="$(id -u kiosk)"
  su kiosk -s /bin/sh -c \
    "AUDIT_LOG='$AL' AUDIT_SPOOL='$ASP' '$SANDBOX/host/probe-audit.sh' audit_event portal-login result=opened" \
    >/dev/null 2>&1
  assert_fails "the kiosk user still cannot read the log" \
    su kiosk -s /bin/sh -c "cat '$AL'"
  assert_not_contains "the unprivileged event is not in the log yet" "$AL" 'portal-login'
  if [ -n "$(ls "$ASP" 2>/dev/null)" ]; then _g "it lands in the spool instead"
  else _b "it lands in the spool instead"; fi

  probe audit_drain 2>/dev/null
  assert_contains "root folds it in, flagged as an unprivileged claim" "$AL" \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z portal-login result=opened via=spool uid='"$kuid"'$'
  if [ -z "$(ls "$ASP" 2>/dev/null)" ]; then _g "and the spool is emptied"
  else _b "and the spool is emptied"; fi

  # A compromised desktop must not be able to invent host observations.
  : > "$AL"
  su kiosk -s /bin/sh -c "printf 'env-switch to=administration idx=3\n' > '$ASP/e-forged'" >/dev/null 2>&1
  probe audit_drain 2>/dev/null
  assert_not_contains "a spooled env-switch is refused (only root observes those)" "$AL" 'env-switch'
  if [ -z "$(ls "$ASP" 2>/dev/null)" ]; then _g "the refused event is still cleaned up"
  else _b "the refused event is still cleaned up"; fi
else
  _g "kiosk user absent in this container — skipping the unprivileged spool checks"
fi

# A symlink in the spool would turn the drain into a root-privileged file
# disclosure straight into the audit log.
: > "$AL"
ln -s "$SANDBOX/config.env" "$ASP/e-symlink"
probe audit_drain 2>/dev/null
assert_not_contains "the drain never follows a symlink" "$AL" 'GUEST_PASSWORD|testpw123'
if [ -e "$ASP/e-symlink" ] || [ -L "$ASP/e-symlink" ]; then
  _b "the symlink is removed rather than retried forever"
else _g "the symlink is removed rather than retried forever"; fi
if [ -f "$SANDBOX/config.env" ]; then _g "and the symlink target is left alone"
else _b "and the symlink target is left alone"; fi

echo
echo "== host/captive-portal.sh audits the login from the kiosk side =="
new_sandbox; mk_probe; audit_paths
PORTAL_BROWSER="sh"; export PORTAL_BROWSER   # skip the browser install in CI
"$SANDBOX/host/captive-portal.sh" > "$SANDBOX/portal.out" 2>&1
assert_eq "captive-portal.sh succeeds" 0 "$?"
assert_mode "it provisions the spool for the kiosk helper" 1733 "$ASP"
KH="$(getent passwd kiosk | cut -d: -f6)"; KH="${KH:-/home/kiosk}"
P="$KH/portal-login.sh"
assert_contains "the helper records an already-online run" "$P" 'audit_event portal-login result=already-online'
assert_contains "the helper records the three outcomes" "$P" 'result=no-portal-found'
assert_contains "and logs before exec replaces the process" "$P" \
  'audit_event portal-login "result=\$result"'
assert_contains "it reuses the shared audit helper rather than its own writer" "$P" 'AUDIT_LIB='
# Belt and braces: the generated helper must be valid POSIX sh.
assert_ok "the generated helper parses as POSIX sh" sh -n "$P"
# Drive it for real as the kiosk user: no portal, no network in the container.
if id kiosk >/dev/null 2>&1; then
  chmod -R a+rX "$SANDBOX" 2>/dev/null || true
  chmod 600 "$AL" 2>/dev/null || true
  su kiosk -s /bin/sh -c "AUDIT_LOG='$AL' AUDIT_SPOOL='$ASP' BROWSER=true '$P'" >/dev/null 2>&1
  probe audit_drain 2>/dev/null
  assert_contains "running it as the kiosk user produces a portal-login event" "$AL" \
    'portal-login result=(opened|no-portal-found|already-online) via=spool'
fi

summary
