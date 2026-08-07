#!/bin/sh
# =============================================================================
# environments/guest-doctor.sh — inspect and repair a guest WITHOUT its help
# -----------------------------------------------------------------------------
# Every other guest tool in this repo talks to the qemu-guest-agent, and the
# agent is installed by cloud-init. So when cloud-init does not provision a
# guest, the operator gets a login prompt no password opens, no desktop, and no
# tool that can tell them why — set-guest-password.sh can only answer "is the VM
# running with the guest agent up?". This script goes in through the host: it
# attaches the guest's qcow2 with qemu-nbd and reads (or fixes) the filesystem
# directly. It needs nothing from inside the guest.
#
# The VM must be SHUT OFF. Touching a disk a live qemu also has open corrupts
# it, so every mode here refuses to run against a running domain.
#
# Usage:
#   guest-doctor.sh                          report on every enabled env
#   guest-doctor.sh office                   report on one env
#   guest-doctor.sh --password office        reset that env's password (prompts)
#   guest-doctor.sh --password all 's3cret'  reset every env's password
#   guest-doctor.sh --install-de office      install the desktop installer
#                                            offline, so it runs on next boot
#   NO_ROOT=1 guest-doctor.sh --password ... change only $GUEST_USER, not root
#
# Deliberately NOT `set -e`: this is a diagnostic. A grep that finds nothing is
# an ANSWER here, not a reason to abort before printing the rest of the report.
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=../lib/guestdisk.sh
. "$HERE/../lib/guestdisk.sh"
# shellcheck source=../lib/de-install.sh
. "$HERE/../lib/de-install.sh"
require_root
load_config
require_cmds virsh qemu-img openssl
export LIBVIRT_DEFAULT_URI=qemu:///system

MODE="report"
NEW_PW=""
targets=""

while [ $# -gt 0 ]; do
  case "$1" in
    --password|--passwd) MODE="password"; shift
      targets="${1:-all}"; [ $# -gt 0 ] && shift
      NEW_PW="${1:-}"; [ $# -gt 0 ] && shift ;;
    --install-de) MODE="install-de"; shift
      targets="${1:-all}"; [ $# -gt 0 ] && shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *)  targets="$targets $1"; shift ;;
  esac
done

[ -n "$(printf '%s' "$targets" | tr -d ' ')" ] || targets="all"
if [ "$(printf '%s' "$targets" | tr -d ' ')" = "all" ]; then
  targets="$(for_each_enabled_env | awk '{print $1}')"
fi

GUEST_USER="${GUEST_USER:-operator}"

# -----------------------------------------------------------------------------
# shadow_state FILE USER — say what a /etc/shadow entry actually permits.
# The distinction that matters: an account with '!' or '*' as its hash cannot be
# logged into at ALL, which is exactly what a guest looks like when cloud-init
# never set a password — and from the console it is indistinguishable from
# "wrong password".
# -----------------------------------------------------------------------------
shadow_state() {
  _sf="$1"; _u="$2"
  [ -f "$_sf" ] || { printf 'no /etc/shadow'; return; }
  _h="$(awk -F: -v u="$_u" '$1==u {print $2; exit}' "$_sf")"
  case "$_h" in
    "")        printf 'NO SUCH USER' ;;
    '!'*|'*'*) printf 'LOCKED (no password can log in)' ;;
    '$6$'*)    printf 'set (sha512-crypt)' ;;
    '$y$'*|'$7$'*) printf 'set (yescrypt)' ;;
    '$'*)      printf 'set (%s)' "$(printf '%s' "$_h" | cut -d'$' -f2)" ;;
    *)         printf 'unrecognised hash' ;;
  esac
}

# -----------------------------------------------------------------------------
# report_one ENV — everything we can learn about this guest, host side first
# (which does not need the disk) then from inside the image.
# -----------------------------------------------------------------------------
report_one() {
  e="$1"
  _os="$(env_val "$e" OS arch)"; _de="$(env_val "$e" DE none)"
  printf '\n\033[1m=== %s (os=%s de=%s) ===\033[0m\n' "$e" "$_os" "$_de"

  if ! virsh dominfo "$e" >/dev/null 2>&1; then
    printf '  domain           : DOES NOT EXIST (run src/environments/create.sh)\n'
    return
  fi
  _state="$(virsh domstate "$e" 2>/dev/null | head -n1)"
  printf '  domain           : %s\n' "$_state"

  _disk="$(gd_domain_disk "$e")"
  _seed="$(gd_domain_seed "$e")"
  printf '  disk             : %s\n' "${_disk:-NONE}"
  if [ -n "$_disk" ] && [ -f "$_disk" ]; then
    printf '  disk virtual size: %s\n' "$(qemu-img info "$_disk" 2>/dev/null | awk -F'[:(]' '/virtual size/ {print $2; exit}' | sed 's/^ *//')"
  fi

  # The cloud-init seed. If this CD-ROM is not attached, cloud-init had nothing
  # to read and NOTHING in the seed was ever applied — no user, no password, no
  # desktop. That is the single most useful line in this report.
  if [ -z "$_seed" ]; then
    printf '  cloud-init seed  : \033[1;31mNOT ATTACHED to the domain\033[0m\n'
  elif [ ! -f "$_seed" ]; then
    printf '  cloud-init seed  : \033[1;31mattached as %s but the FILE IS GONE\033[0m\n' "$_seed"
    printf '                     (scrub-secrets.sh SCRUB_SEEDS=1 deletes it; the guest\n'
    printf '                      cannot be re-provisioned without rebuilding the seed)\n'
  else
    printf '  cloud-init seed  : %s (%s bytes)\n' "$_seed" "$(wc -c < "$_seed" 2>/dev/null | tr -d ' ')"
  fi

  if [ -z "$_disk" ] || [ ! -f "$_disk" ]; then
    printf '  guest filesystem : cannot inspect (no disk file)\n'; return
  fi
  if ! gd_require_off "$e"; then
    printf '  guest filesystem : \033[1;33mNOT INSPECTED — the VM is running.\033[0m\n'
    printf '                     Shut it down and re-run:  virsh shutdown %s\n' "$e"
    return
  fi
  if [ "$(env_val "$e" ENCRYPT_DISK 0)" = "1" ]; then
    printf '  guest filesystem : not inspected (LUKS-encrypted disk)\n'; return
  fi

  trap 'gd_detach' EXIT INT TERM
  if ! gd_attach "$_disk" ro; then
    printf '  guest filesystem : could not attach the disk (see warning above)\n'
    trap - EXIT INT TERM; return
  fi

  printf '  --- inside the guest ---\n'
  printf '  hostname         : %s\n' "$(cat "$GD_MNT/etc/hostname" 2>/dev/null || echo '(none)')"

  # cloud-init's own verdict. /var/lib/cloud survives a shutdown (unlike the
  # /run copies), and the instance directory is named after the meta-data
  # instance-id we generated — so seeing our env name here proves cloud-init
  # actually read OUR seed rather than some other datasource.
  if [ -d "$GD_MNT/var/lib/cloud/instances" ]; then
    printf '  cloud-init ran as: %s\n' "$(ls "$GD_MNT/var/lib/cloud/instances" 2>/dev/null | tr '\n' ' ')"
  else
    printf '  cloud-init ran as: \033[1;31mNEVER RAN (no /var/lib/cloud/instances)\033[0m\n'
  fi
  if [ -f "$GD_MNT/var/lib/cloud/instance/datasource" ]; then
    printf '  datasource       : %s\n' "$(cat "$GD_MNT/var/lib/cloud/instance/datasource" 2>/dev/null)"
  else
    printf '  datasource       : \033[1;31mnone recorded — the seed was not consumed\033[0m\n'
  fi

  printf '  %-16s : %s\n' "user '$GUEST_USER'" "$(shadow_state "$GD_MNT/etc/shadow" "$GUEST_USER")"
  printf '  %-16s : %s\n' "user 'root'" "$(shadow_state "$GD_MNT/etc/shadow" root)"
  # The Ubuntu cloud image's built-in account, reported because operators reach
  # for it by reflex: our seed replaces `users:` wholesale, so it is NOT created.
  if [ "$_os" = "ubuntu" ]; then
    printf '  %-16s : %s\n' "user 'ubuntu'" "$(shadow_state "$GD_MNT/etc/shadow" ubuntu)"
  fi

  # Desktop
  if [ "$_de" != "none" ]; then
    if [ -f "$GD_MNT/var/lib/appliance-de.done" ]; then
      printf '  desktop install  : DONE\n'
    elif [ -f "$GD_MNT/var/lib/appliance-de.nospace" ]; then
      printf '  desktop install  : \033[1;31mABORTED — guest disk too small\033[0m\n'
    elif [ -f "$GD_MNT/usr/local/sbin/appliance-install-de.sh" ]; then
      printf '  desktop install  : \033[1;33marmed but not completed\033[0m\n'
    else
      printf '  desktop install  : \033[1;31mnever armed (the installer is not in the image)\033[0m\n'
    fi
    _tgt="$(readlink "$GD_MNT/etc/systemd/system/default.target" 2>/dev/null | sed 's|.*/||')"
    printf '  default target   : %s\n' "${_tgt:-(distro default, normally multi-user)}"
    if [ -f "$GD_MNT/var/log/de-install.log" ]; then
      printf '  --- de-install.log (last 12) ---\n'
      tail -n 12 "$GD_MNT/var/log/de-install.log" 2>/dev/null | sed 's/^/    /'
    fi
  fi

  # Root-filesystem usage, because "no space" is the failure this whole class of
  # bug hides behind.
  printf '  root fs usage    : %s\n' "$(df -Pm "$GD_MNT" 2>/dev/null | awk 'NR==2 {printf "%sMB used, %sMB free (%s)", $3, $4, $5}')"

  if [ -f "$GD_MNT/var/log/cloud-init.log" ]; then
    _err="$(grep -iE 'traceback|CRITICAL|ERROR' "$GD_MNT/var/log/cloud-init.log" 2>/dev/null | tail -n 8)"
    if [ -n "$_err" ]; then
      printf '  --- cloud-init.log errors (last 8) ---\n'
      printf '%s\n' "$_err" | sed 's/^/    /'
    else
      printf '  cloud-init errors: none logged\n'
    fi
  else
    printf '  cloud-init log   : \033[1;31mabsent — cloud-init never started\033[0m\n'
  fi

  gd_detach
  trap - EXIT INT TERM
}

# -----------------------------------------------------------------------------
# set_password_one ENV — write the password straight into the guest's
# /etc/shadow, creating the account if cloud-init never did. This is the path
# that works when nothing inside the guest works.
# -----------------------------------------------------------------------------
set_password_one() {
  e="$1"; hash="$2"
  virsh dominfo "$e" >/dev/null 2>&1 || { warn "$e: no such domain — skipping."; return 1; }
  gd_require_off "$e" || {
    warn "$e: the VM is RUNNING. Shut it down first:  virsh shutdown $e   (then re-run)"
    return 1
  }
  if [ "$(env_val "$e" ENCRYPT_DISK 0)" = "1" ]; then
    warn "$e: LUKS-encrypted disk — offline password reset is not supported."; return 1
  fi
  _disk="$(gd_domain_disk "$e")"
  [ -n "$_disk" ] && [ -f "$_disk" ] || { warn "$e: no disk file found."; return 1; }

  trap 'gd_detach' EXIT INT TERM
  gd_attach "$_disk" rw || { trap - EXIT INT TERM; return 1; }

  _with_root=1; [ "${NO_ROOT:-0}" = "1" ] && _with_root=0
  if ! awk -F: -v u="$GUEST_USER" '$1==u {found=1} END {exit !found}' "$GD_MNT/etc/passwd"; then
    warn "$e: '$GUEST_USER' does not exist in this guest — creating it."
  fi
  if ! gd_set_password "$GD_MNT" "$GUEST_USER" "$hash" "$_with_root"; then
    gd_detach; trap - EXIT INT TERM; return 1
  fi

  gd_detach
  trap - EXIT INT TERM
  if [ "$_with_root" = "1" ]; then
    ok "$e: password set for '$GUEST_USER' and root."
  else
    ok "$e: password set for '$GUEST_USER'."
  fi
  return 0
}

# -----------------------------------------------------------------------------
# install_de_one ENV — put the desktop installer into a guest that never got it,
# so the desktop appears on the next boot without rebuilding the VM.
# -----------------------------------------------------------------------------
install_de_one() {
  e="$1"
  _os="$(env_val "$e" OS arch)"; _de="$(env_val "$e" DE none)"
  [ "$_de" != "none" ] || { warn "$e: ${e}_DE=none — nothing to install."; return 0; }
  de_resolve "$_os" "$_de" || { warn "$e: no desktop resolved."; return 1; }
  gd_require_off "$e" || { warn "$e: the VM is RUNNING. Shut it down first."; return 1; }
  _disk="$(gd_domain_disk "$e")"
  [ -n "$_disk" ] && [ -f "$_disk" ] || { warn "$e: no disk file found."; return 1; }

  trap 'gd_detach' EXIT INT TERM
  gd_attach "$_disk" rw || { trap - EXIT INT TERM; return 1; }

  mkdir -p "$GD_MNT/usr/local/sbin" "$GD_MNT/etc/systemd/system/multi-user.target.wants"
  de_script "$_os" "$_de" > "$GD_MNT/usr/local/sbin/appliance-install-de.sh"
  chmod 755 "$GD_MNT/usr/local/sbin/appliance-install-de.sh"
  de_unit > "$GD_MNT/etc/systemd/system/appliance-de.service"
  chmod 644 "$GD_MNT/etc/systemd/system/appliance-de.service"
  # Enable it the way systemctl would have: WantedBy=multi-user.target is just
  # this symlink, and we cannot run systemctl inside an offline image.
  ln -sf /etc/systemd/system/appliance-de.service \
     "$GD_MNT/etc/systemd/system/multi-user.target.wants/appliance-de.service"

  _alp="$(de_autologin_path "$DE_DM")"
  if [ -n "$_alp" ]; then
    mkdir -p "$GD_MNT$(dirname "$_alp")"
    de_autologin_content "$DE_DM" "$GUEST_USER" "$DE_SESSION" > "$GD_MNT$_alp"
  fi
  # lightdm autologin also needs the user in the `autologin` group (Arch enforces
  # this); do it offline since we cannot run gpasswd in the image.
  if [ "$DE_DM" = "lightdm" ]; then
    _grf="$GD_MNT/etc/group"
    awk -F: '$1=="autologin" {found=1} END {exit !found}' "$_grf" \
      || printf 'autologin:x:%s:\n' "$(awk -F: '$3>=900 && $3<1000 {m=($3>m)?$3:m} END {print (m?m+1:990)}' "$_grf")" >> "$_grf"
    gd_group_add "$_grf" autologin "$GUEST_USER"
  fi

  rm -f "$GD_MNT/var/lib/appliance-de.nospace" 2>/dev/null
  gd_detach
  trap - EXIT INT TERM
  ok "$e: desktop installer armed ($_de via $DE_DM). It runs on the next boot; watch /var/log/de-install.log in the guest."
  return 0
}

# -----------------------------------------------------------------------------
# Dispatch.
# -----------------------------------------------------------------------------
gd_supported || warn "qemu-nbd/nbd module unavailable — offline inspection will not work on this host."

rc=0
case "$MODE" in
  report)
    for e in $targets; do report_one "$e"; done
    cat <<'EOF'

How to read this
  "cloud-init ran as: NEVER RAN" or "datasource: none recorded"
      -> the seed was never consumed. Nothing in it applied: no user, no
         password, no desktop. Check the "cloud-init seed" line above.
  "user 'operator': LOCKED" or "NO SUCH USER"
      -> no password can log in. Fix it without rebuilding:
             ./src/environments/guest-doctor.sh --password <env>
  "desktop install: never armed"
      -> arm it offline, it runs on the next boot:
             ./src/environments/guest-doctor.sh --install-de <env>
EOF
    ;;
  password)
    if [ -z "$NEW_PW" ]; then
      printf 'New password for %s (input hidden): ' "$GUEST_USER" >&2
      stty -echo 2>/dev/null || true
      read -r NEW_PW
      stty echo 2>/dev/null || true
      printf '\n' >&2
    fi
    [ -n "$NEW_PW" ] || die "Empty password — aborting."
    # Hash once on the host: openssl is a required dependency here and every
    # guest distro accepts sha512-crypt in /etc/shadow.
    HASH="$(openssl passwd -6 "$NEW_PW")" || die "openssl passwd -6 failed."
    for e in $targets; do set_password_one "$e" "$HASH" || rc=1; done
    ;;
  install-de)
    for e in $targets; do install_de_one "$e" || rc=1; done
    ;;
esac

exit "$rc"
