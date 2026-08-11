#!/bin/sh
# lib/common.sh
# -----------------------------------------------------------------------------
# Shared helpers sourced by every script. POSIX sh so it also works
# under Alpine's default /bin/sh (busybox ash). Scripts that need bashisms
# set their own shebang; this file avoids them.
# -----------------------------------------------------------------------------

# --- pretty logging ----------------------------------------------------------
# All logging goes to STDERR so functions that return a value via stdout
# (make_seed, require_secret, env_* helpers) are never polluted by log output.
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# step "TITLE" — a bold section header, so the operator can see where they are in
# a multi-stage script (create/isolate/build all run many sub-steps). Cosmetic.
step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*" >&2; }

# run CMD [ARGS...] — run a NOISY command quietly. Its stdout+stderr are captured
# and shown ONLY if it fails (or always when VERBOSE=1), so the console stays at
# clean [*]/[+]/[!] lines instead of pages of wget/apk/qemu-img/pacman chatter —
# while an error is never hidden. Returns the command's own exit status, so the
# usual `run … || die` / `set -e` handling is unchanged.
#
# ONLY for commands whose stdout is not captured by the caller (a value-returning
# `x="$(cmd)"` must NOT be wrapped — run redirects stdout into the log file).
run() {
  if [ "${VERBOSE:-0}" = "1" ]; then "$@"; return $?; fi
  _run_log="$(mktemp 2>/dev/null || echo /tmp/run.$$.log)"
  if "$@" >"$_run_log" 2>&1; then
    rm -f "$_run_log"; return 0
  fi
  _run_rc=$?
  warn "command failed (exit $_run_rc): $*"
  sed 's/^/      /' "$_run_log" >&2 2>/dev/null || cat "$_run_log" >&2
  rm -f "$_run_log"
  return "$_run_rc"
}

# --- guards ------------------------------------------------------------------
require_root() {
  [ "$(id -u)" = "0" ] || die "Must run as root (use sudo)."
}

# require_cmds cmd1 cmd2 ... — fail listing everything missing at once.
require_cmds() {
  missing=""
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] || die "Missing dependencies:$missing"
}

# --- audit trail (CONTRACT B) ------------------------------------------------
# /var/log/appliance-audit.log, mode 0600 root:root, append only, one line per
# event:   <ISO8601-UTC> <event> <key=value> [<key=value>...]
# This is the traceability record a multi-level workstation owes you after an
# incident: which environment was active when, which peripheral was routed
# where, when someone authenticated to the captive portal. Because it is read
# after the fact and never during a decision, it must NEVER be the reason a
# security script aborts — every entry point below degrades to a warning and
# returns 0.
AUDIT_LOG="${AUDIT_LOG:-/var/log/appliance-audit.log}"
# Drop directory for writers that are not root. The desktop runs as the
# unprivileged kiosk user (Super+p portal login, Super+y USB chooser) and must
# never be able to read or rewrite a 0600 root-owned log. It drops one file per
# event here instead, and the next root-run audit_event folds them in. Mode
# 1733: other users may create files (-wx) but cannot list the directory, and
# the sticky bit stops them unlinking or replacing anyone else's event.
AUDIT_SPOOL="${AUDIT_SPOOL:-/var/log/appliance-audit.d}"
# Events accepted FROM THE SPOOL. Whatever the kiosk drops there is
# attacker-controlled the moment the desktop is compromised, so it may only
# claim the two events it legitimately produces. env-switch and
# isolation-check are host observations: a spooled one would be a forgery.
AUDIT_SPOOL_EVENTS="portal-login usb-route"
# The appliance disk is small and an append-only log only grows. Rotate at
# 256 KiB (~3000 events) keeping a single .1 — two files is all the history
# this facility promises.
AUDIT_MAX_BYTES="${AUDIT_MAX_BYTES:-262144}"

# _audit_clean STRING — make STRING safe as ONE field of ONE line. Whitespace
# becomes '_' because a value with a space parses as two fields and a value with
# a newline forges an entire event; everything outside a conservative printable
# set is dropped so a USB product string or a portal URL cannot smuggle control
# characters into the log. An empty value stays visible as '-' rather than
# silently shortening the line.
_audit_clean() {
  _ac="$(printf '%s' "${1:-}" | tr '\n\r\t\013\014' '     ' | tr -s ' ' '_' \
       | tr -cd 'a-zA-Z0-9_.:,=+@%/-')"
  printf '%s' "${_ac:--}"
}

_audit_size() { stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || printf '0'; }

# _audit_ensure — create the log and the spool. Root only: nobody else can.
_audit_ensure() {
  [ "$(id -u)" = "0" ] || return 0
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
  # umask on creation, never chmod: this creates a missing log at 0600 and is
  # physically incapable of widening one that already exists.
  [ -e "$AUDIT_LOG" ] || ( umask 077; : >> "$AUDIT_LOG" ) 2>/dev/null || true
  [ -d "$AUDIT_SPOOL" ] || { mkdir -p "$AUDIT_SPOOL" && chmod 1733 "$AUDIT_SPOOL"; } 2>/dev/null || true
  return 0
}

# _audit_rotate — bound the log, keeping one generation. mv preserves the mode,
# so the .1 stays as tight as the log it came from.
_audit_rotate() {
  [ -f "$AUDIT_LOG" ] || return 0
  [ "$(_audit_size "$AUDIT_LOG")" -ge "$AUDIT_MAX_BYTES" ] 2>/dev/null || return 0
  mv -f "$AUDIT_LOG" "$AUDIT_LOG.1" 2>/dev/null || return 0
  ( umask 077; : >> "$AUDIT_LOG" ) 2>/dev/null || true
}

# _audit_append LINE — the only writer. A single short printf into a file opened
# with O_APPEND is one write() syscall, and Linux serialises appends, so two
# concurrent writers interleave whole lines and never half a line. That is why
# there is no lock file here: a lock would be one more thing that can wedge a
# security script, for a guarantee the kernel already gives us at these sizes.
_audit_append() {
  ( umask 077; printf '%s\n' "$1" >> "$AUDIT_LOG" ) 2>/dev/null
}

# audit_drain — fold spooled unprivileged events into the log. Root only.
# Everything read here is untrusted input from a possibly-compromised desktop,
# so: never follow a symlink, cap the size, cap how many files one call will
# process (a flooding kiosk must not stall a security script), re-clean every
# field, and refuse any event name outside $AUDIT_SPOOL_EVENTS.
audit_drain() {
  [ "$(id -u)" = "0" ] || return 0
  [ -d "$AUDIT_SPOOL" ] || return 0
  _an=0
  for _asf in "$AUDIT_SPOOL"/e-*; do
    [ -e "$_asf" ] || continue                       # unmatched glob
    _an=$((_an+1)); [ "$_an" -le 200 ] || break
    if [ ! -L "$_asf" ] && [ -f "$_asf" ] && [ "$(_audit_size "$_asf")" -le 512 ]; then
      _araw="$(head -n1 "$_asf" 2>/dev/null || true)"
      _aev="$(_audit_clean "${_araw%% *}")"
      case " $AUDIT_SPOOL_EVENTS " in
        *" $_aev "*)
          # Timestamp from the file's mtime, not from anything inside the file:
          # the drain can happen minutes later and the log must show when the
          # event happened. The kiosk owns the file and could backdate it, so a
          # future mtime is clamped to now and the line is marked via=spool —
          # an analyst can see the timing is an unprivileged claim.
          _amt="$(stat -c %Y "$_asf" 2>/dev/null || printf '0')"
          _anow="$(date -u +%s)"
          _ats=""
          if [ "$_amt" -gt 0 ] 2>/dev/null && [ "$_amt" -le "$_anow" ] 2>/dev/null; then
            _ats="$(date -u -r "$_asf" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '')"
          fi
          [ -n "$_ats" ] || _ats="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
          _aline="$_ats $_aev"
          _arest=""
          case "$_araw" in *" "*) _arest="${_araw#* }" ;; esac
          for _af in $_arest; do _aline="$_aline $(_audit_clean "$_af")"; done
          _aline="$_aline via=spool uid=$(stat -c %u "$_asf" 2>/dev/null || printf '?')"
          _audit_rotate
          _audit_append "$_aline" || true ;;
        *) : ;;                                       # not a kiosk-claimable event
      esac
    fi
    rm -f "$_asf" 2>/dev/null || true
  done
  return 0
}

# audit_init — provision the log and the spool and pick up anything the kiosk
# left behind. Call it from root-run scripts whose unprivileged sibling paths
# need somewhere to drop events. No-op for non-root.
audit_init() { _audit_ensure || true; audit_drain || true; return 0; }

_audit_emit() {
  [ $# -ge 1 ] || return 0
  _aev="$(_audit_clean "$1")"; shift
  _abody="$_aev"
  for _af in "$@"; do _abody="$_abody $(_audit_clean "$_af")"; done
  if [ "$(id -u)" = "0" ]; then
    _audit_ensure
    audit_drain                                       # spooled events are older
    _audit_rotate
    _audit_append "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $_abody" \
      || warn "audit: cannot write $AUDIT_LOG (event $_aev not recorded)"
    return 0
  fi
  # Unprivileged caller: drop it in the spool for root to pick up. Widening the
  # log or handing the kiosk a privilege would both be worse than a small delay.
  if [ -d "$AUDIT_SPOOL" ] &&
     ( umask 077; printf '%s\n' "$_abody" > "$AUDIT_SPOOL/e-$$-$(date -u +%s)" ) 2>/dev/null; then
    return 0
  fi
  warn "audit: no writable spool (event $_aev not recorded)"
  return 0
}

# audit_event EVENT [key=value ...] — record one event (CONTRACT B).
# The `|| true` is load-bearing: callers run under `set -e`, and an audit log
# that cannot be written must never abort the security action it was recording.
audit_event() { _audit_emit "$@" || true; return 0; }

# audit_tail [N] — last N events (default 20), oldest first, spanning the
# rotated generation so a rotation does not hide the recent past.
audit_tail() {
  { [ -f "$AUDIT_LOG.1" ] && cat "$AUDIT_LOG.1"; cat "$AUDIT_LOG"; } 2>/dev/null | tail -n "${1:-20}"
}

# --- config.env plumbing -----------------------------------------------------
# Scripts live in src/<group>/ (src/host/, src/environments/, ...), so the
# project root is TWO levels up from the calling script's dir. config.env and
# config.env.example live at that root. The flat legacy layout (<group>/ one
# level under the root — old appliances, the test sandbox) is still recognised.
_caller_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "$(basename "$(dirname "$_caller_dir")")" = "src" ]; then
  APP_ROOT="$(cd "$_caller_dir/../.." && pwd)"
else
  APP_ROOT="$(cd "$_caller_dir/.." && pwd)"
fi
unset _caller_dir
CONFIG_ENV="$APP_ROOT/config.env"
# Consumed by sourcing scripts (e.g. host/detect-and-install.sh seeds config.env
# from it); shellcheck can't see cross-file use of a sourced library variable.
# shellcheck disable=SC2034
CONFIG_EXAMPLE="$APP_ROOT/config.env.example"

load_config() {
  [ -f "$CONFIG_ENV" ] || die "config.env not found. Run src/host/detect-and-install.sh first."
  # Self-heal permissions: config.env carries secrets, so it must never be
  # readable by the kiosk user. An older appliance (or a hand-edited file) can
  # still be 0644 — tighten it whenever a root-run script reads it.
  [ "$(id -u)" = "0" ] && chmod 600 "$CONFIG_ENV" 2>/dev/null
  # shellcheck disable=SC1090
  . "$CONFIG_ENV"
}

# set_kv KEY VALUE — idempotently upsert KEY="VALUE" into config.env.
# config.env holds SECRETS (guest/root passwords, Wi-Fi PSK, LUKS + VPN keys) and
# is world-readable-by-default otherwise: the rewrite below creates a fresh temp
# file, so without an explicit umask the replacement would come back as 0644 and
# hand every local account — including the unprivileged kiosk desktop user — the
# whole secret set. Create it 0600 and keep it that way on every write.
set_kv() {
  key="$1"; val="$2"
  ( umask 077; touch "$CONFIG_ENV" )
  # remove any existing line for this key, then append the new one.
  ( umask 077
    grep -v "^${key}=" "$CONFIG_ENV" > "$CONFIG_ENV.tmp" 2>/dev/null || true
    printf '%s="%s"\n' "$key" "$val" >> "$CONFIG_ENV.tmp" )
  mv "$CONFIG_ENV.tmp" "$CONFIG_ENV"
  chmod 600 "$CONFIG_ENV" 2>/dev/null || true
  export "$key=$val"
}

# require_secret KEY — return the value of config var KEY. Secrets are NEVER
# auto-generated: a value the operator did not choose is a value they cannot
# know (a generated root/LUKS password locks them out of their own machine).
# An empty value, or the legacy literal "generate", is a hard error.
require_secret() {
  _k="$1"; _v="$(eval "printf '%s' \"\${${_k}:-}\"")"
  [ -n "$_v" ] && [ "$_v" != "generate" ] || \
    die "$_k is not set in config.env (secrets are never auto-generated). Set an explicit value — re-run ./setup-image.sh or edit config.env."
  printf '%s' "$_v"
}

# scrub_secrets — blank all secret values in config.env once consumed
# (passwords baked into VMs, PSK hashed, LUKS/VPN keys applied). Structural
# config ($ENVS, per-env OS/DE/egress) is kept so scripts still work.
scrub_secrets() {
  for k in GUEST_PASSWORD WIFI_PSK LUKS_PASS HOST_ROOT_PASSWORD; do
    grep -q "^${k}=" "$CONFIG_ENV" 2>/dev/null && set_kv "$k" ""
  done
  for _e in ${ENVS:-}; do
    grep -q "^${_e}_VPN_PRIVKEY=" "$CONFIG_ENV" 2>/dev/null && set_kv "${_e}_VPN_PRIVKEY" ""
    grep -q "^${_e}_DISK_PASS="   "$CONFIG_ENV" 2>/dev/null && set_kv "${_e}_DISK_PASS" ""
  done
  warn "Scrubbed secrets from config.env (password/PSK/LUKS/VPN keys blanked)."
}

# -----------------------------------------------------------------------------
# Environment (VM) model helpers.
# $ENVS is an ordered, space-separated list of environment names (e.g.
# "office development administration"). Each env <e> has per-env config vars
# read by convention: ${e}_ENABLED, ${e}_OS, ${e}_DE, ${e}_EGRESS_MODE, ...
# The POSITION in $ENVS (1-based) fixes its workspace number, /24 subnet and
# bridge — so enabling/disabling an env never renumbers the others.
# -----------------------------------------------------------------------------
# env_val ENV SUFFIX [DEFAULT] -> value of ${ENV}_${SUFFIX}, or DEFAULT.
env_val() {
  _v="$(eval "printf '%s' \"\${${1}_${2}:-}\"")"
  [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "${3:-}"
}
# env_index ENV -> its 1-based position in $ENVS (empty if not found).
env_index() {
  _i=0
  for _e in $ENVS; do _i=$((_i+1)); [ "$_e" = "$1" ] && { printf '%s' "$_i"; return; }; done
}
# env_enabled ENV -> 0 (true) if ${ENV}_ENABLED != 0, else 1 (false).
env_enabled() { [ "$(env_val "$1" ENABLED 1)" != "0" ]; }
# for_each_enabled_env: prints "<env> <index>" per enabled env, in order.
# The explicit `return 0` is load-bearing: without it the function's exit status
# is that of the LAST iteration's `[ … ] && printf`, which is non-zero whenever
# the last-listed env is DISABLED. Callers pipe this into `while read` under
# `set -o pipefail` + `set -e`, so a non-zero here aborts the whole script the
# moment an operator disables the last env in ENVS.
for_each_enabled_env() {
  _i=0
  for _e in $ENVS; do
    _i=$((_i+1))
    [ "$(env_val "$_e" ENABLED 1)" != "0" ] && printf '%s %s\n' "$_e" "$_i"
  done
  return 0
}
# Derived, stable per-env attributes (by name/index).
env_net()    { printf 'isol-%s' "$1"; }             # libvirt network name
env_bridge() { printf 'virbr%s' "$2"; }             # bridge iface (<=15 chars)
env_subnet() { printf '%s.%s' "${SUBNET_BASE:-10.10}" "$2"; }  # /24 third octet = index
# OS -> base image / os-variant / download URL.
# windows has NO cloud base image (it installs from an operator-supplied ISO);
# os_base prints a sentinel so the create loop does not treat it as "unsupported
# OS" and skip it — create_windows_vm ignores the value.
os_base()    { case "$1" in ubuntu) printf '%s/base-ubuntu.img' "$IMAGES_DIR";; arch) printf '%s/base-arch.qcow2' "$IMAGES_DIR";; debian) printf '%s/base-debian.qcow2' "$IMAGES_DIR";; windows) printf 'windows-iso';; *) return 1;; esac; }
os_variant() { case "$1" in ubuntu) printf '%s' "${UBUNTU_OS_VARIANT:-ubuntu22.04}";; arch) printf '%s' "${ARCH_OS_VARIANT:-archlinux}";; debian) printf '%s' "${DEBIAN_OS_VARIANT:-debian12}";; windows) printf '%s' "${WINDOWS_OS_VARIANT:-win11}";; esac; }
# os_family: apt-based (ubuntu/debian) vs arch vs windows. Drives which
# provisioning path create.sh takes (cloud-init seed vs autounattend ISO).
os_family()  { case "$1" in ubuntu|debian) printf 'apt';; arch) printf 'arch';; windows) printf 'windows';; *) printf 'apt';; esac; }
# Upper-case an env name for trust-bar labels (office -> OFFICE). Portable.
env_title() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
