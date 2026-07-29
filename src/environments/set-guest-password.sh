#!/bin/sh
# =============================================================================
# environments/set-guest-password.sh — force-change a guest's password LIVE
# -----------------------------------------------------------------------------
# Resets the login password (and, by default, root) inside a running VM via the
# qemu-guest-agent — no rebuild, no reboot. Handy when the baked GUEST_PASSWORD
# is wrong/forgotten or you want a distinct password per environment.
#
# Usage:
#   environments/set-guest-password.sh                 # all enabled envs, prompt for pw
#   environments/set-guest-password.sh office          # one env, prompt for pw
#   environments/set-guest-password.sh office 's3cret'  # one env, explicit pw
#   environments/set-guest-password.sh all 's3cret'     # all enabled envs, explicit pw
#   NO_ROOT=1 environments/set-guest-password.sh ...    # change only $GUEST_USER, not root
#
# Requires the guest to be running with qemu-guest-agent up (installed by
# create.sh's cloud-init). If the agent isn't ready yet, wait for first boot to
# finish and retry.
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config
require_cmds virsh
export LIBVIRT_DEFAULT_URI=qemu:///system

want="${1:-all}"
new_pw="${2:-}"

# Which envs? "all" (default) or a single named, enabled env.
if [ "$want" = "all" ]; then
  targets="$(for_each_enabled_env | awk '{print $1}')"
else
  env_enabled "$want" 2>/dev/null || warn "$want is not marked enabled — trying anyway."
  targets="$want"
fi
[ -n "$targets" ] || die "No target environment(s) found."

# Password: from arg, else prompt (no echo). Refuse empty.
if [ -z "$new_pw" ]; then
  printf 'New password for %s (input hidden): ' "$GUEST_USER" >&2
  stty -echo 2>/dev/null || true
  read -r new_pw
  stty echo 2>/dev/null || true
  printf '\n' >&2
fi
[ -n "$new_pw" ] || die "Empty password — aborting."

USER_NAME="${GUEST_USER:-operator}"

set_one() {
  dom="$1"; acct="$2"
  # virsh set-user-password drives the guest agent to change the password.
  if virsh set-user-password "$dom" "$acct" "$new_pw" >/dev/null 2>&1; then
    ok "[$dom] password changed for '$acct'."
  else
    warn "[$dom] could NOT set '$acct' password (is the VM running with the guest agent up?)."
    return 1
  fi
}

rc=0
for e in $targets; do
  virsh dominfo "$e" >/dev/null 2>&1 || { warn "$e: no such domain — skipping."; rc=1; continue; }
  set_one "$e" "$USER_NAME" || rc=1
  [ "${NO_ROOT:-0}" = "1" ] || set_one "$e" root || true
done

[ "$rc" = 0 ] && ok "Done." || warn "Some changes failed — see warnings above."
exit "$rc"
