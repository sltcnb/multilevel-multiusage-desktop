#!/bin/sh
# tests/test-common.sh — lib/common.sh: the environment model + config handling.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== lib/common.sh =="
new_sandbox
# common.sh derives APP_ROOT from $0's parent, so source it via a script that
# lives one level down, exactly like the real callers do.
cat > "$SANDBOX/host/probe.sh" <<'EOF'
#!/bin/sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
load_config
"$@"
EOF
chmod +x "$SANDBOX/host/probe.sh"
probe() { "$SANDBOX/host/probe.sh" "$@"; }

# --- the environment model ---------------------------------------------------
assert_eq "env_index: position is 1-based and follows \$ENVS order" \
  "2" "$(probe env_index development)"
assert_eq "env_subnet: third octet == index" \
  "10.10.3" "$(probe env_subnet administration 3)"
assert_eq "env_bridge: virbr<idx>, <=15 chars" \
  "virbr2" "$(probe env_bridge development 2)"
assert_eq "env_net: per-env libvirt network name" \
  "isol-office" "$(probe env_net office)"
assert_eq "env_val: falls back to the supplied default" \
  "gnome" "$(probe env_val office DE gnome)"
assert_eq "env_title: upper-cased label for the trust bar" \
  "OFFICE" "$(probe env_title office)"
assert_eq "os_family: ubuntu and debian are apt, arch is not" \
  "apt apt arch" "$(probe os_family ubuntu) $(probe os_family debian) $(probe os_family arch)"

# Disabling an env must NOT renumber the others (positions are fixed by $ENVS).
sed -i 's/^development_ENABLED=.*/development_ENABLED=0/' "$SANDBOX/config.env"
assert_eq "disabling an env leaves the other indices untouched" \
  "office 1
administration 3" "$(probe for_each_enabled_env)"
sed -i 's/^development_ENABLED=.*/development_ENABLED=1/' "$SANDBOX/config.env"

# --- config.env permissions --------------------------------------------------
# config.env holds the guest/root passwords, the Wi-Fi PSK and the LUKS keys, so
# it must never be readable by the unprivileged kiosk user.
chmod 644 "$SANDBOX/config.env"
probe true >/dev/null 2>&1
assert_mode "load_config tightens a world-readable config.env to 0600" 600 "$SANDBOX/config.env"

chmod 644 "$SANDBOX/config.env"
probe set_kv TEST_KEY test-value >/dev/null 2>&1
assert_mode "set_kv leaves config.env at 0600 after rewriting it" 600 "$SANDBOX/config.env"
assert_contains "set_kv writes the key" "$SANDBOX/config.env" '^TEST_KEY="test-value"$'
probe set_kv TEST_KEY second >/dev/null 2>&1
assert_eq "set_kv is an upsert, not an append" \
  "1" "$(grep -c '^TEST_KEY=' "$SANDBOX/config.env")"

# --- secrets -----------------------------------------------------------------
out="$(probe resolve_secret GUEST_PASSWORD 2>/dev/null)"
assert_eq "resolve_secret returns the configured value verbatim" "testpw123" "$out"

probe set_kv SOME_SECRET generate >/dev/null 2>&1
gen="$(probe resolve_secret SOME_SECRET 2>/dev/null)"
[ -n "$gen" ] && [ "$gen" != "generate" ] && _g "resolve_secret replaces \"generate\" with a random value" \
  || _b "resolve_secret replaces \"generate\" with a random value"
assert_contains_fixed "the generated value is persisted to config.env" \
  "$SANDBOX/config.env" "SOME_SECRET=\"$gen\""
# It must go to the root-only note file and NOT to the console: stderr lands on
# the kiosk tty during the unattended first boot.
err="$(probe resolve_secret ANOTHER_SECRET 2>&1 >/dev/null)"
new="$(grep '^ANOTHER_SECRET=' "$SANDBOX/config.env" | cut -d'"' -f2)"
case "$err" in
  *"$new"*) _b "resolve_secret must not echo the generated secret to the console" ;;
  *) _g "resolve_secret must not echo the generated secret to the console" ;;
esac

# scrub_secrets blanks every sensitive key but keeps the structure.
probe scrub_secrets >/dev/null 2>&1
assert_contains "scrub_secrets blanks GUEST_PASSWORD"   "$SANDBOX/config.env" '^GUEST_PASSWORD=""$'
assert_contains "scrub_secrets blanks WIFI_PSK"         "$SANDBOX/config.env" '^WIFI_PSK=""$'
assert_contains "scrub_secrets blanks per-env DISK_PASS" "$SANDBOX/config.env" '^office_DISK_PASS=""$'
assert_contains "scrub_secrets keeps the structural config" "$SANDBOX/config.env" '^ENVS='

summary
