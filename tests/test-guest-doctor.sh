#!/bin/sh
# tests/test-guest-doctor.sh — the offline guest repair path.
#
# The point of this path is that it works when NOTHING inside the guest does, so
# the tests exercise it the same way: against a plain directory that looks like
# a guest root filesystem. No qemu-nbd, no libvirt, no cloud-init — exactly the
# functions that edit /etc/passwd and /etc/shadow, on files we can read back.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== environments/guest-doctor.sh + lib/guestdisk.sh + lib/de-install.sh =="

new_sandbox
# lib.sh carries common + guestdisk + de-install (and windows-unattend) in one file.
# shellcheck source=/dev/null
. "$SANDBOX/src/lib.sh"

HASH='$6$testsalt$0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmno'

# fake_root DIR [locked|nouser] — a minimal guest filesystem.
fake_root() {
  d="$1"; kind="${2:-locked}"
  rm -rf "$d"; mkdir -p "$d/etc/skel" "$d/home"
  cat > "$d/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
EOF
  cat > "$d/etc/group" <<'EOF'
root:x:0:
sudo:x:27:
adm:x:4:
sudoers:x:900:
EOF
  cat > "$d/etc/shadow" <<'EOF'
root:*:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
EOF
  if [ "$kind" = "locked" ]; then
    printf 'operator:x:1000:1000::/home/operator:/bin/bash\n' >> "$d/etc/passwd"
    printf 'operator:!:19000:0:99999:7:::\n' >> "$d/etc/shadow"
  fi
  chmod 640 "$d/etc/shadow"
}

sh_field() { awk -F: -v u="$2" '$1==u {print $3; exit}' "$1/etc/shadow"; }
sh_hash()  { awk -F: -v u="$2" '$1==u {print $2; exit}' "$1/etc/shadow"; }

# --- an existing but LOCKED account (cloud-init created the user and never set
#     a password) is the exact state that reads as "wrong password" at a console.
R="$SANDBOX/root-locked"; fake_root "$R" locked
assert_ok "gd_set_password succeeds on a locked account" gd_set_password "$R" operator "$HASH" 1
assert_eq "the locked account gets the hash" "$HASH" "$(sh_hash "$R" operator)"
assert_eq "root gets the same hash" "$HASH" "$(sh_hash "$R" root)"
if [ -n "$(sh_field "$R" operator)" ]; then
  _g "the last-changed field is set (an empty one forces a password change at login)"
else
  _b "the last-changed field is set (an empty one forces a password change at login)"
fi
assert_mode "/etc/shadow stays root-only" 640 "$R/etc/shadow"
assert_eq "no duplicate shadow entry is created" 1 \
  "$(grep -c '^operator:' "$R/etc/shadow")"

# NO_ROOT equivalent: root must be left alone when asked.
R2="$SANDBOX/root-noroot"; fake_root "$R2" locked
gd_set_password "$R2" operator "$HASH" 0 >/dev/null 2>&1
assert_eq "with_root=0 leaves root untouched" '*' "$(sh_hash "$R2" root)"

# --- the account does NOT exist at all (cloud-init never ran) ------------------
R3="$SANDBOX/root-nouser"; fake_root "$R3" nouser
assert_ok "gd_set_password creates a missing account" gd_set_password "$R3" operator "$HASH" 1
assert_contains "the account is added to /etc/passwd" "$R3/etc/passwd" '^operator:x:1000:1000::/home/operator:/bin/bash$'
assert_eq "the created account gets the hash" "$HASH" "$(sh_hash "$R3" operator)"
assert_contains "the account joins the apt admin group" "$R3/etc/group" '^sudo:x:27:operator$'
assert_contains "the account joins adm too" "$R3/etc/group" '^adm:x:4:operator$'
assert_contains "passwordless sudo is granted" "$R3/etc/sudoers.d/90-appliance-operator" 'operator ALL=\(ALL\) NOPASSWD:ALL'
assert_mode "the sudoers drop-in is 0440 (sudo refuses anything looser)" 440 "$R3/etc/sudoers.d/90-appliance-operator"
if [ -d "$R3/home/operator" ]; then _g "a home directory is created"; else _b "a home directory is created"; fi
# A group whose NAME contains another group's name must not be matched.
assert_contains "'sudoers' is not mistaken for 'sudo'" "$R3/etc/group" '^sudoers:x:900:$'

# --- gd_group_add is idempotent ----------------------------------------------
gd_group_add "$R3/etc/group" sudo operator
assert_eq "adding the same member twice does not duplicate it" 1 \
  "$(awk -F: '$1=="sudo" {n=split($4,a,","); print n}' "$R3/etc/group")"

# --- lib/de-install.sh --------------------------------------------------------
de_resolve ubuntu mate  && assert_eq "ubuntu+mate resolves to the mate metapackage" "ubuntu-mate-desktop lightdm" "$DE_PKGS"
de_resolve arch gnome   && assert_eq "arch+gnome uses gdm, not gdm3"                 "gdm" "$DE_DM"
de_resolve debian xfce4 && assert_eq "debian+xfce4 pulls xorg explicitly"            "xfce" "$DE_SESSION"
if de_resolve ubuntu none; then _b "DE=none resolves to nothing"; else _g "DE=none resolves to nothing"; fi

de_script ubuntu mate > "$SANDBOX/de-mate.sh"
assert_ok "the generated installer is valid POSIX shell" sh -n "$SANDBOX/de-mate.sh"
assert_contains "the installer logs where an operator will look for it" "$SANDBOX/de-mate.sh" '/var/log/de-install.log'
de_script arch xfce4 > "$SANDBOX/de-xfce.sh"
assert_ok "the arch installer is valid POSIX shell" sh -n "$SANDBOX/de-xfce.sh"
assert_contains "the arch installer clears a stale pacman lock" "$SANDBOX/de-xfce.sh" 'db.lck'

de_unit > "$SANDBOX/de.service"
assert_contains "the retry unit is oneshot" "$SANDBOX/de.service" '^Type=oneshot$'
assert_contains "the retry unit retries" "$SANDBOX/de.service" '^Restart=on-failure$'

assert_eq "lightdm autologin goes in a drop-in, not the main config" \
  "/etc/lightdm/lightdm.conf.d/50-appliance-autologin.conf" "$(de_autologin_path lightdm)"
assert_eq "gdm3 autologin lands in custom.conf" "/etc/gdm3/custom.conf" "$(de_autologin_path gdm3)"

# --- the report runs against the stubbed host without a disk ------------------
new_sandbox
"$SANDBOX/src/environments.sh" create >/dev/null 2>&1
"$SANDBOX/src/environments.sh" guest-doctor office > "$SANDBOX/doctor.out" 2>&1
assert_contains "the report names the environment" "$SANDBOX/doctor.out" '=== office'
assert_contains "the report tells the operator how to fix a locked account" "$SANDBOX/doctor.out" 'guest-doctor --password'

# An env that was never created must say so rather than half-report.
"$SANDBOX/src/environments.sh" guest-doctor nosuchenv > "$SANDBOX/doctor2.out" 2>&1
assert_contains "an absent domain is reported plainly" "$SANDBOX/doctor2.out" 'DOES NOT EXIST'

# Refuse to touch a RUNNING domain — mounting a live qcow2 corrupts it.
touch "$SANDBOX/stub-state/running-office"
"$SANDBOX/src/environments.sh" guest-doctor --password office 'newpw123' > "$SANDBOX/doctor3.out" 2>&1
assert_contains "a running VM is refused, with the command to fix it" "$SANDBOX/doctor3.out" 'RUNNING'

summary
