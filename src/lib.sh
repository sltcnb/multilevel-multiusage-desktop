#!/bin/sh
# =============================================================================
# src/lib.sh — the shared library, SOURCED by every appliance script.
# -----------------------------------------------------------------------------
# Merged from the former src/lib/{common,de-install,guestdisk,windows-unattend}.sh
# so the tree carries one library file instead of four. POSIX sh (busybox ash
# compatible); sourced, never executed. Section banners below mark the original
# file boundaries.
# =============================================================================


# ===================== [ common ] =====================
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
  [ -f "$CONFIG_ENV" ] || die "config.env not found. Run src/host.sh detect-and-install first."
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
    die "$_k is not set in config.env (secrets are never auto-generated). Set an explicit value — re-run ./configure.sh or edit config.env."
  printf '%s' "$_v"
}

# scrub_secrets — blank all secret values in config.env once consumed
# (passwords baked into VMs, PSK hashed, LUKS/VPN keys applied). Structural
# config ($ENVS, per-env OS/DE/egress) is kept so scripts still work.
scrub_secrets() {
  for k in GUEST_PASSWORD WIFI_PSK LUKS_PASS HOST_ROOT_PASSWORD NETBIRD_SETUP_KEY; do
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


# ===================== [ de-install ] =====================
# lib/de-install.sh
# -----------------------------------------------------------------------------
# ONE definition of "how a guest gets a desktop", shared by:
#   * environments/create.sh    — bakes it into the cloud-init seed
#   * environments/guest-doctor.sh — drops it straight into a guest disk when
#                                 cloud-init never ran at all
#
# It used to live only inside create.sh, as printf format strings full of \n
# escapes nested in YAML nested in shell. That is unreviewable, it is why the
# installer could not be reused by any repair path, and every fix to it had to
# be made blind. Here it is plain text emitted by plain functions.
# -----------------------------------------------------------------------------

# de_resolve OS DE — set DE_PKGS / DE_DM / DE_SESSION for this distro+desktop.
# Package names differ per distro; the display manager and session names are
# what the autologin drop-in below needs. Returns 1 for DE=none.
# shellcheck disable=SC2034  # DE_SESSION is read by this file's callers.
de_resolve() {
  _os="$1"; _de="$2"
  [ "$_de" != "none" ] && [ -n "$_de" ] || return 1
  case "$_os" in
    ubuntu)
      case "$_de" in
        xfce4) DE_PKGS="xubuntu-desktop-minimal lightdm"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
        gnome) DE_PKGS="ubuntu-desktop-minimal gdm3";     DE_DM="gdm3";    DE_SESSION="ubuntu" ;;
        kde)   DE_PKGS="kde-plasma-desktop sddm";         DE_DM="sddm";    DE_SESSION="plasma" ;;
        mate)  DE_PKGS="ubuntu-mate-desktop lightdm";     DE_DM="lightdm"; DE_SESSION="mate" ;;
        lxqt)  DE_PKGS="lubuntu-desktop sddm";            DE_DM="sddm";    DE_SESSION="lxqt" ;;
        *) warn "Unknown DE '$_de'; defaulting to xfce4."
           DE_PKGS="xubuntu-desktop-minimal lightdm"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
      esac ;;
    debian)
      case "$_de" in
        xfce4) DE_PKGS="xorg xfce4 xfce4-goodies lightdm"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
        gnome) DE_PKGS="gnome-core gdm3";                  DE_DM="gdm3";    DE_SESSION="gnome" ;;
        kde)   DE_PKGS="kde-plasma-desktop sddm";          DE_DM="sddm";    DE_SESSION="plasma" ;;
        mate)  DE_PKGS="mate-desktop-environment lightdm"; DE_DM="lightdm"; DE_SESSION="mate" ;;
        lxqt)  DE_PKGS="lxqt sddm";                        DE_DM="sddm";    DE_SESSION="lxqt" ;;
        *) warn "Unknown DE '$_de'; defaulting to xfce4."
           DE_PKGS="xorg xfce4 lightdm"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
      esac ;;
    *)  # arch — needs the xorg group spelled out, and the greeter package
      case "$_de" in
        xfce4) DE_PKGS="xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
        gnome) DE_PKGS="gnome gdm";                                            DE_DM="gdm";     DE_SESSION="gnome" ;;
        kde)   DE_PKGS="plasma-meta sddm";                                     DE_DM="sddm";    DE_SESSION="plasma" ;;
        mate)  DE_PKGS="xorg mate mate-extra lightdm lightdm-gtk-greeter";     DE_DM="lightdm"; DE_SESSION="mate" ;;
        lxqt)  DE_PKGS="xorg lxqt sddm";                                       DE_DM="sddm";    DE_SESSION="lxqt" ;;
        *) warn "Unknown DE '$_de'; defaulting to xfce4."
           DE_PKGS="xorg xfce4 lightdm lightdm-gtk-greeter"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
      esac ;;
  esac
  return 0
}

# de_min_disk_mb DE — rough floor for "this desktop can actually be unpacked".
# A full ubuntu-mate-desktop plus Edge is ~6 GiB installed on top of a ~2 GiB
# base, and create.sh will happily hand a guest a 10 GiB disk (its DISK_GB
# fallback is 10, and detect-and-install's auto-split floor is 8). apt then dies
# part-way with "You don't have enough free space", which reads in the log as an
# ordinary package error and left the VM desktop-less with no obvious cause.
# Check it up front and say the real reason.
de_min_disk_mb() {
  case "$1" in
    gnome|kde|mate) printf '7000' ;;
    lxqt|xfce4)     printf '5000' ;;
    *)              printf '5000' ;;
  esac
}

# de_script OS DE — print /usr/local/sbin/appliance-install-de.sh.
#
# Design notes, all of them scars:
#  * A LOCK. The unit below is enabled for retries AND cloud-init runs this
#    script directly on the first boot. Two concurrent apt runs would deadlock
#    on the dpkg lock, so whoever gets there second exits quietly.
#  * A SPACE PRE-FLIGHT, so "the disk is too small" says so instead of hiding
#    inside apt's output.
#  * dpkg REPAIR first. An install killed part-way (the old code let cloud-init
#    reboot mid-apt) leaves dpkg interrupted, and every later attempt then fails
#    with "dpkg was interrupted" forever.
#  * The display manager is enabled and the default target switched, but the DM
#    is NOT started synchronously here — see de_unit for why.
de_script() {
  _os="$1"; _de="$2"
  de_resolve "$_os" "$_de" || return 1
  _min="$(de_min_disk_mb "$_de")"
  # spice-vdagent rides along with every desktop: it is what lets the guest track
  # the viewer's window size (virt-viewer --auto-resize). Without it the guest is
  # stuck at a fixed low resolution that the viewer scales up — the pixelated,
  # doesn't-fill-the-screen symptom. Same package name on apt and Arch.
  _pkgs="$DE_PKGS spice-vdagent"
  if [ "$(os_family "$_os")" = "apt" ]; then
    _install="DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold $_pkgs"
    _refresh="apt-get update"
    _repair="dpkg --configure -a || true
apt-get -f install -y || true"
  else
    _install="pacman -Sy --noconfirm --needed $_pkgs"
    _refresh="pacman -Sy --noconfirm"
    _repair="rm -f /var/lib/pacman/db.lck || true"
  fi

  cat <<EOF
#!/bin/sh
# Appliance desktop installer — generated by lib/de-install.sh. Retried by
# appliance-de.service until the repos are reachable, then self-disables.
exec >>/var/log/de-install.log 2>&1
echo "=== [de] \$(date -u '+%Y-%m-%dT%H:%M:%SZ') attempt (os=$_os de=$_de) ==="

[ -f /var/lib/appliance-de.done ] && { echo "[de] already installed - nothing to do"; exit 0; }

# Only one attempt at a time: cloud-init runs this directly on the first boot
# while appliance-de.service may also fire it. mkdir is the atomic test.
if ! mkdir /run/appliance-de.lock 2>/dev/null; then
  echo "[de] another attempt already running - skipping"; exit 0
fi
trap 'rmdir /run/appliance-de.lock 2>/dev/null' EXIT INT TERM HUP

free_mb=\$(df -Pm / | awk 'NR==2 {print \$4}')
echo "[de] free space on /: \${free_mb}MB (need >= $_min MB for $_de)"
if [ "\${free_mb:-0}" -lt $_min ]; then
  echo "[de] FATAL - not enough disk for the $_de desktop."
  echo "[de] The guest disk is too small. Give this env a bigger disk on the HOST:"
  echo "[de]   set <env>_DISK_GB in config.env, then RECREATE=<env> ./src/environments.sh create"
  echo "[de] Not retrying - a retry cannot create disk space."
  touch /var/lib/appliance-de.nospace
  exit 0
fi

$_repair

if ! $_refresh; then
  echo "[de] package index refresh FAILED - no repos reachable yet."
  echo "[de] (no internet? captive portal not cleared? check the HOST uplink)"
  echo "[de] will retry in 30s"
  exit 1
fi

if ! $_install; then
  echo "[de] package install FAILED - will retry in 30s"
  exit 1
fi

systemctl set-default graphical.target || true
systemctl enable $DE_DM || true
# The daemon side of the resize/clipboard agent; the per-session client is
# autostarted by the desktop. Without it running, --auto-resize does nothing.
systemctl enable --now spice-vdagentd || true
touch /var/lib/appliance-de.done
systemctl disable appliance-de.service || true
echo "[de] OK - desktop installed, display manager '$DE_DM' enabled"

# Bring the desktop up now if we are NOT inside cloud-init's first boot. During
# cloud-init, starting graphical.target synchronously can deadlock against the
# transaction that is still bringing up multi-user.target — cloud-init reboots
# once on its own (power_state) and the desktop comes up there instead.
if [ ! -e /run/cloud-init/status.json ] || [ -f /run/cloud-init/result.json ]; then
  systemctl start graphical.target --no-block || true
fi
EOF
}

# de_unit — print /etc/systemd/system/appliance-de.service.
#
# The installer is NEVER waited on synchronously by cloud-init. It used to be
# (`systemctl start --wait appliance-de.service`), and that is a trap: the unit
# carries Restart=on-failure, so on a guest with no internet yet systemd keeps
# restarting it and `--wait` never returns — cloud-final hangs for the whole
# boot, every boot. cloud-init calls the SCRIPT directly instead (bounded, it
# either installs or returns non-zero), and this unit exists purely to retry on
# later boots.
de_unit() {
  cat <<'EOF'
[Unit]
Description=Appliance desktop install (retries until the repos are reachable)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/appliance-de.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/appliance-install-de.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

# de_autologin_path DM — where the autologin drop-in for this DM goes.
de_autologin_path() {
  case "$1" in
    lightdm) printf '/etc/lightdm/lightdm.conf.d/50-appliance-autologin.conf' ;;
    gdm3)    printf '/etc/gdm3/custom.conf' ;;
    gdm)     printf '/etc/gdm/custom.conf' ;;
    sddm)    printf '/etc/sddm.conf.d/50-appliance-autologin.conf' ;;
  esac
}

# de_autologin_content DM USER SESSION — the drop-in itself.
# lightdm gets a conf.d drop-in rather than a rewritten lightdm.conf, so a
# distro's own seat configuration survives.
de_autologin_content() {
  case "$1" in
    lightdm) printf '[Seat:*]\nautologin-user=%s\nautologin-session=%s\nautologin-user-timeout=0\n' "$2" "$3" ;;
    gdm3|gdm) printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$2" ;;
    sddm)    printf '[Autologin]\nUser=%s\nSession=%s\n' "$2" "$3" ;;
  esac
}

# de_autologin_extra_cmd DM USER — a shell command the guest must ALSO run for
# autologin to work, or empty. Arch's lightdm refuses to autologin a user who is
# not in the `autologin` group, and that group does not exist until something
# creates it — so a correct-looking drop-in silently did nothing and the env sat
# at a greeter.
de_autologin_extra_cmd() {
  case "$1" in
    lightdm) printf "groupadd -r autologin 2>/dev/null || true; gpasswd -a %s autologin 2>/dev/null || true" "$2" ;;
    *) : ;;
  esac
}


# ===================== [ guestdisk ] =====================
# lib/guestdisk.sh
# -----------------------------------------------------------------------------
# Mount a SHUT-OFF guest's qcow2 from the host, with no help from the guest.
#
# Why this exists: every other tool we had for looking into (or repairing) a VM
# went through the qemu-guest-agent — and the agent is installed by cloud-init.
# So the one failure that matters most, "cloud-init did not provision this
# guest", took out the diagnosis and the repair path along with it: no agent, no
# password, no way in, and set-guest-password.sh could only say "is the VM
# running with the guest agent up?". This file breaks that circle. qemu-nbd
# exposes the disk as a block device on the host, so /etc/shadow and
# /var/log/cloud-init.log are ordinary files we can read and write.
#
# qemu-nbd ships in Alpine's qemu-img package, which the appliance already
# installs (src/build.sh), so this adds no new dependency.
#
# SAFETY: the caller MUST verify the domain is shut off. Attaching a qcow2 that
# a running qemu also has open gives an inconsistent view at best and corrupts
# the image at worst. gd_attach refuses to guess about that — see
# gd_require_off in the callers.
#
# Usage:
#   gd_attach /path/disk.qcow2 ro   # or rw
#   ... read/write under "$GD_MNT" ...
#   gd_detach
# -----------------------------------------------------------------------------

GD_NBD=""      # /dev/nbdN currently connected (empty when detached)
GD_MNT=""      # mountpoint of the guest root filesystem

# gd_supported — print nothing, return 0 if this host can do offline mounts.
gd_supported() {
  command -v qemu-nbd >/dev/null 2>&1 || return 1
  modprobe nbd max_part=16 2>/dev/null || true
  [ -b /dev/nbd0 ]
}

# gd_detach — always safe to call, including when nothing is attached. Kept
# idempotent because every caller wires it into a trap and it therefore runs
# again on the way out of an error path that already cleaned up.
gd_detach() {
  if [ -n "$GD_MNT" ] && mountpoint -q "$GD_MNT" 2>/dev/null; then
    umount "$GD_MNT" 2>/dev/null || umount -l "$GD_MNT" 2>/dev/null || true
  fi
  [ -n "$GD_MNT" ] && rmdir "$GD_MNT" 2>/dev/null
  if [ -n "$GD_NBD" ]; then
    qemu-nbd -d "$GD_NBD" >/dev/null 2>&1 || true
  fi
  GD_NBD=""; GD_MNT=""
  return 0
}

# _gd_free_nbd — first /dev/nbdN with no server attached. /sys/block/nbdN/pid
# only exists while a qemu-nbd process owns the device, which is the check
# qemu-nbd itself races on, so we test it rather than trusting nbd0 to be idle.
_gd_free_nbd() {
  _i=0
  while [ "$_i" -lt 16 ]; do
    if [ -b "/dev/nbd$_i" ] && [ ! -e "/sys/block/nbd$_i/pid" ]; then
      printf '/dev/nbd%s' "$_i"; return 0
    fi
    _i=$((_i+1))
  done
  return 1
}

# gd_attach DISK [ro|rw] — connect DISK and mount its ROOT filesystem at $GD_MNT.
#
# "Root filesystem" is found by probing, not by assuming a partition number: the
# Ubuntu cloud image puts root on p1 with a BIOS-grub p14 and an ESP p15, Debian
# uses p1, and Arch's cloudimg has an ESP ahead of root. A partition counts as
# root when it carries /etc/passwd — that also rejects the ESP, which would
# otherwise mount happily and read as an empty guest.
gd_attach() {
  _disk="$1"; _mode="${2:-ro}"
  [ -f "$_disk" ] || { warn "guestdisk: $_disk does not exist."; return 1; }
  gd_supported || {
    warn "guestdisk: qemu-nbd or the 'nbd' kernel module is unavailable — cannot inspect guest disks offline."
    return 1
  }
  GD_NBD="$(_gd_free_nbd)" || { warn "guestdisk: no free /dev/nbd* device."; return 1; }

  if [ "$_mode" = "rw" ]; then
    qemu-nbd -c "$GD_NBD" -f qcow2 "$_disk" >/dev/null 2>&1
  else
    qemu-nbd --read-only -c "$GD_NBD" -f qcow2 "$_disk" >/dev/null 2>&1
  fi || {
    warn "guestdisk: qemu-nbd could not attach $_disk (encrypted disk, or already in use by a running VM?)."
    GD_NBD=""; return 1
  }

  # The kernel scans the partition table asynchronously after connect; without
  # this the /dev/nbdNp* nodes are frequently not there yet on the first look.
  udevadm settle >/dev/null 2>&1 || sleep 1
  partprobe "$GD_NBD" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || sleep 1

  GD_MNT="$(mktemp -d)"
  # SECURITY: mount with `nosymfollow` (Linux >=5.10). The guest fully controls
  # its own disk while it is shut off, so it can pre-plant a symlink at any path
  # a host-side offline edit will touch (/etc/shadow, /etc/sudoers.d/*, the
  # de-install script under /usr/local/sbin, /home/<user>) whose ABSOLUTE target
  # the host kernel resolves against the HOST root. A later `guest-doctor.sh
  # --password/--install-de` or the create.sh login pre-seed would then write
  # THROUGH that symlink as root, into a host file — a VM->host root escape that
  # breaks the whole multi-level premise. `nosymfollow` makes the kernel refuse
  # to traverse ANY symlink on this mount, so such a write fails closed instead.
  # None of the files these paths touch are symlinks on a stock cloud image, so
  # legitimate access is unaffected. Fall back (with a LOUD warning, never
  # silently) on kernels/mount binaries without the option, so the recovery path
  # still works — but the operator is told the hardening is off.
  _ro=""; [ "$_mode" = "rw" ] || _ro="ro,"
  for _try in "${_ro}nosymfollow" "__legacy__"; do
    if [ "$_try" = "__legacy__" ]; then
      warn "guestdisk: 'nosymfollow' unsupported here — offline guest-disk edits are NOT hardened against guest-planted symlinks (needs Linux>=5.10 + util-linux/busybox mount that supports it). Only inspect/repair guests you trust."
      _try="${_ro%,}"
    fi
    for _p in "$GD_NBD"p* "$GD_NBD"; do
      [ -b "$_p" ] || continue
      if [ -n "$_try" ]; then
        mount -o "$_try" "$_p" "$GD_MNT" 2>/dev/null || continue
      else
        mount "$_p" "$GD_MNT" 2>/dev/null || continue
      fi
      if [ -f "$GD_MNT/etc/passwd" ]; then return 0; fi
      umount "$GD_MNT" 2>/dev/null || true
    done
  done

  warn "guestdisk: no partition on $_disk carries /etc/passwd — nothing to inspect."
  gd_detach
  return 1
}

# gd_require_off DOM — 0 when the domain exists and is not running. Everything
# in this file is unsafe against a live qemu, so callers gate on this and say so
# out loud rather than mounting anyway and hoping.
gd_require_off() {
  _st="$(virsh domstate "$1" 2>/dev/null | head -n1 | tr -d '\r')"
  case "$_st" in
    "shut off"|"") return 0 ;;
    *) return 1 ;;
  esac
}

# gd_domain_disk DOM — the domain's main writable disk (its qcow2). domblklist
# also lists the cloud-init seed CD-ROM, so select on the extension rather than
# taking the first row.
gd_domain_disk() {
  virsh domblklist "$1" 2>/dev/null | awk '$2 ~ /\.qcow2$/ {print $2; exit}'
}

# gd_domain_seed DOM — the seed ISO the domain has attached, if any.
gd_domain_seed() {
  virsh domblklist "$1" 2>/dev/null | awk '$2 ~ /seed\.iso$/ {print $2; exit}'
}

# -----------------------------------------------------------------------------
# gd_set_password MNT USER HASH [WITH_ROOT]
#   Set USER's password (a crypt HASH) in the guest root filesystem mounted at
#   MNT, creating the account with sudo rights if it does not exist. WITH_ROOT=1
#   gives root the same hash.
#
#   This is the login path that does NOT go through cloud-init. It is used both
#   to pre-seed a brand new disk (environments/create.sh) and to rescue a guest
#   cloud-init never provisioned (environments/guest-doctor.sh). Editing
#   /etc/shadow by hand is unglamorous, but it is the only method that still
#   works when the thing that was supposed to create the account did not run —
#   and being locked out of all three environments with no recovery is a worse
#   outcome than any elegance we would buy by insisting on the guest's own tools.
# -----------------------------------------------------------------------------
gd_set_password() {
  _mnt="$1"; _user="$2"; _hash="$3"; _with_root="${4:-1}"
  _pwf="$_mnt/etc/passwd"; _shf="$_mnt/etc/shadow"; _grf="$_mnt/etc/group"
  [ -f "$_pwf" ] && [ -f "$_shf" ] || { warn "guestdisk: $_mnt has no /etc/passwd+/etc/shadow."; return 1; }
  # shadow's "last changed" field, in days since the epoch. Leaving it EMPTY
  # means "must change password at next login", which would lock the operator
  # out again the moment they used the password we just set.
  _days="$(( $(date -u +%s) / 86400 ))"

  if awk -F: -v u="$_user" '$1==u {found=1} END {exit !found}' "$_pwf"; then
    # Account exists: replace the hash, reset the ageing fields.
    awk -F: -v u="$_user" -v h="$_hash" -v d="$_days" 'BEGIN{OFS=":"}
      $1==u { $2=h; $3=d; $5=99999 } {print}' "$_shf" > "$_shf.tmp" \
      && cat "$_shf.tmp" > "$_shf"
    rm -f "$_shf.tmp"
  else
    # Account missing: create it. First free uid at or above 1000, its own
    # group, a home directory from /etc/skel, and passwordless sudo — the same
    # shape the cloud-init seed would have produced.
    _uid=1000
    while awk -F: -v i="$_uid" '$3==i {found=1} END {exit !found}' "$_pwf"; do _uid=$((_uid+1)); done
    printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$_user" "$_uid" "$_uid" "$_user" >> "$_pwf"
    printf '%s:x:%s:\n' "$_user" "$_uid" >> "$_grf"
    printf '%s:%s:%s:0:99999:7:::\n' "$_user" "$_hash" "$_days" >> "$_shf"
    mkdir -p "$_mnt/home/$_user" 2>/dev/null
    cp -a "$_mnt/etc/skel/." "$_mnt/home/$_user/" 2>/dev/null || true
    chown -R "$_uid:$_uid" "$_mnt/home/$_user" 2>/dev/null || true
    chmod 750 "$_mnt/home/$_user" 2>/dev/null || true
    # Admin group: apt images ship sudo/adm, the Arch image ships wheel. Join
    # whichever actually exist rather than inventing one sudoers ignores.
    for _g in sudo adm wheel; do
      awk -F: -v g="$_g" '$1==g {found=1} END {exit !found}' "$_grf" || continue
      gd_group_add "$_grf" "$_g" "$_user"
    done
    mkdir -p "$_mnt/etc/sudoers.d" 2>/dev/null
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$_user" > "$_mnt/etc/sudoers.d/90-appliance-$_user"
    chmod 440 "$_mnt/etc/sudoers.d/90-appliance-$_user" 2>/dev/null || true
  fi

  if [ "$_with_root" = "1" ]; then
    awk -F: -v h="$_hash" -v d="$_days" 'BEGIN{OFS=":"}
      $1=="root" { $2=h; $3=d; $5=99999 } {print}' "$_shf" > "$_shf.tmp" \
      && cat "$_shf.tmp" > "$_shf"
    rm -f "$_shf.tmp"
  fi

  # /etc/shadow must never become world-readable. cat-into-place kept the
  # original inode and mode, but be explicit — a file we created ourselves would
  # otherwise carry our umask.
  chmod 640 "$_shf" 2>/dev/null || true
  return 0
}

# gd_group_add GROUPFILE GROUP USER — add USER to GROUP's member list in an
# offline /etc/group, idempotently. The comma-wrapped index test is what stops
# "sudo" matching inside "sudoers" and stops a second run duplicating the name.
gd_group_add() {
  _gf="$1"; _g="$2"; _u="$3"
  awk -F: -v g="$_g" -v u="$_u" 'BEGIN{OFS=":"}
    $1==g { if ($4=="") $4=u; else if (index(","$4",", ","u",")==0) $4=$4","u }
    {print}' "$_gf" > "$_gf.tmp" && cat "$_gf.tmp" > "$_gf"
  rm -f "$_gf.tmp"
}

# -----------------------------------------------------------------------------
# gd_seed_network MNT OSFAMILY
#   Write a "DHCP on any ethernet" network config straight into the guest root
#   filesystem mounted at MNT, so the NIC comes up WITHOUT cloud-init.
#
#   Same rationale as gd_set_password: networking that works only if cloud-init's
#   network module succeeds is a single point of failure — and it has been seen
#   to fail, leaving the interface up-but-unconfigured (IPv6 link-local only, no
#   IPv4, no route). Everything downstream then dies: no DHCP lease -> no default
#   route -> "network unreachable" -> apt cannot reach the repos -> no
#   qemu-guest-agent, no desktop, and a boot that stalls waiting on
#   network-online.target for its full timeout.
#
#   Two things are written:
#     1. The renderer's own DHCP config (netplan for apt distros, a
#        systemd-networkd .network for Arch). `optional: true` / no wait keeps a
#        momentarily-down link from dragging the boot out.
#     2. /etc/cloud/cloud.cfg.d/99-appliance-disable-network.cfg turning cloud-
#        init network management OFF, so cloud-init does not ALSO emit a config
#        that fights ours over the same interface (a double match breaks netplan).
#
#   OSFAMILY is os_family's output: "apt" (ubuntu/debian) or anything else (arch).
#   Matching is by glob (e*/en*/eth*), never a hardcoded ens3: the interface name
#   depends on the machine type, and pinning one is exactly the kind of breakage
#   this function exists to avoid.
# -----------------------------------------------------------------------------
gd_seed_network() {
  _mnt="$1"; _fam="$2"
  [ -d "$_mnt/etc" ] || { warn "guestdisk: $_mnt has no /etc — cannot seed networking."; return 1; }

  # Take networking out of cloud-init's hands so it cannot emit a competing
  # config. This file is read by every cloud-init version.
  mkdir -p "$_mnt/etc/cloud/cloud.cfg.d" 2>/dev/null
  printf 'network: {config: disabled}\n' \
    > "$_mnt/etc/cloud/cloud.cfg.d/99-appliance-disable-network.cfg"

  if [ "$_fam" = "apt" ]; then
    # netplan (renderer networkd — the cloud/server default). Files apply in
    # lexical order and later wins, so 99- overrides any 50-cloud-init.yaml that
    # is already there. 0600: netplan warns (and future versions may refuse) on
    # a world-readable config.
    mkdir -p "$_mnt/etc/netplan" 2>/dev/null
    ( umask 077
      cat > "$_mnt/etc/netplan/99-appliance-dhcp.yaml" <<'NP'
network:
  version: 2
  renderer: networkd
  ethernets:
    appliance-dhcp:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: false
      optional: true
NP
    )
  else
    # systemd-networkd. Among matching .network files networkd applies the
    # lexically FIRST, so a low number (05-) makes ours authoritative over any
    # image default like 20-ethernet.network.
    mkdir -p "$_mnt/etc/systemd/network" 2>/dev/null
    cat > "$_mnt/etc/systemd/network/05-appliance-dhcp.network" <<'ND'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCP]
RouteMetric=100
ND
    # Make sure networkd + resolved actually run — the offline equivalent of
    # `systemctl enable systemd-networkd systemd-resolved`. Best-effort: the Arch
    # cloud image usually enables them already, and a stale symlink is harmless.
    _ulib="/usr/lib/systemd/system"
    mkdir -p "$_mnt/etc/systemd/system/multi-user.target.wants" \
             "$_mnt/etc/systemd/system/sockets.target.wants" 2>/dev/null
    ln -sf "$_ulib/systemd-networkd.service" \
       "$_mnt/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null
    ln -sf "$_ulib/systemd-networkd.socket" \
       "$_mnt/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" 2>/dev/null
    ln -sf "$_ulib/systemd-resolved.service" \
       "$_mnt/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" 2>/dev/null
    # DNS via resolved's stub, so name resolution works once the link is up.
    ln -sf /run/systemd/resolve/stub-resolv.conf "$_mnt/etc/resolv.conf" 2>/dev/null || true
  fi
  return 0
}


# ===================== [ windows-unattend ] =====================
# lib/windows-unattend.sh
# -----------------------------------------------------------------------------
# ONE definition of "how a Windows 11 office guest gets provisioned unattended",
# the Windows counterpart to lib/de-install.sh (which is cloud-init/Linux only).
#
# Windows has no cloud-init and no downloadable cloud image, so the Linux path in
# environments/create.sh (fetch qcow2 -> NoCloud seed -> cloud-init) does not
# apply. Instead Windows Setup reads an answer file named autounattend.xml from
# the root of any attached removable/optical media and installs hands-free. This
# file emits that answer file; create.sh wraps it in a small ISO and attaches it
# alongside the operator-supplied Windows ISO.
#
# Deliberate reliability choices (this path CANNOT be pre-seeded or repaired
# offline the way the Linux guests can — there is no /etc/shadow or netplan to
# edit on NTFS — so the install must succeed on the first pass):
#   * TARGET DISK = SATA/AHCI, not virtio. Windows 11 has an inbox AHCI driver,
#     so Setup sees the disk with NO driver injection in WinPE (the single most
#     common unattended-install failure). virtio-blk would need a viostor driver
#     loaded in WinPE from the virtio-win media — fragile and drive-letter
#     dependent. Perf for a desktop is fine on AHCI; the operator can migrate to
#     virtio later if they want.
#   * NIC = e1000e (set in create.sh), also an inbox Windows driver, so the guest
#     has working DHCP/network during OOBE and at first boot with no driver step.
#   * The Win11 hardware gates (TPM 2.0 + Secure Boot + >=4 GB) are SATISFIED by
#     the q35+UEFI+vTPM profile create.sh gives this guest, so NO registry bypass
#     is needed — the install is a supported configuration, not a hack.
#   * virtio-win guest tools (qemu-guest-agent + qxldod + virtio drivers) and the
#     SPICE guest tools (spice-vdagent, for viewer auto-resize) are installed by
#     FirstLogonCommands, scanning drive letters because WinPE/OOBE letters are
#     not stable. qemu-guest-agent is what environments/isolate.sh talks to.
# -----------------------------------------------------------------------------

# win_min_disk_mb — floor for a Windows 11 install (~20 GB OS + headroom). Well
# below the 64 GB create.sh defaults, but a guard against a hand-set tiny disk.
win_min_disk_mb() { printf '30000'; }

# _win_xml_escape STRING — make STRING safe inside an XML text node/attribute.
# The guest password flows into the answer file verbatim, so & < > " ' must be
# entity-escaped or Setup rejects the file (or worse, sets a truncated password).
_win_xml_escape() {
  printf '%s' "${1:-}" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# win_autounattend USER PASS HOSTNAME [LOCALE] [TZ] — print autounattend.xml.
#   USER/PASS    — the local administrator created for the operator (same
#                  GUEST_PASSWORD the Linux guests use).
#   HOSTNAME     — computer name (<=15 chars; caller trims).
#   LOCALE       — Windows locale tag, default en-US.
#   TZ           — Windows time-zone id, default "UTC" (matches the appliance).
win_autounattend() {
  _wu_user="$1"; _wu_pass="$2"; _wu_host="$3"
  _wu_locale="${4:-en-US}"; _wu_tz="${5:-UTC}"
  _wu_user_x="$(_win_xml_escape "$_wu_user")"
  _wu_pass_x="$(_win_xml_escape "$_wu_pass")"
  _wu_host_x="$(_win_xml_escape "$_wu_host")"
  # Windows computer names are <=15 chars and a limited charset; the caller passes
  # an env name (office), which is safe, but trim defensively.
  _wu_host_x="$(printf '%.15s' "$_wu_host_x")"

  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>$_wu_locale</UILanguage></SetupUILanguage>
      <InputLocale>$_wu_locale</InputLocale>
      <SystemLocale>$_wu_locale</SystemLocale>
      <UILanguage>$_wu_locale</UILanguage>
      <UserLocale>$_wu_locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 11 Pro</Value></MetaData>
          </InstallFrom>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>$_wu_user_x</FullName>
        <Organization>Appliance</Organization>
        <!-- Public KMS client setup key for Win11 Pro: lets Setup proceed
             unattended, does NOT activate. Activation is done post-install via
             Entra/Intune or a KMS/MAK key (governance/licensing decision). -->
        <ProductKey><Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key><WillShowUI>OnError</WillShowUI></ProductKey>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$_wu_host_x</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$_wu_locale</InputLocale>
      <SystemLocale>$_wu_locale</SystemLocale>
      <UILanguage>$_wu_locale</UILanguage>
      <UserLocale>$_wu_locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>$_wu_tz</TimeZone>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$_wu_user_x</Name>
            <DisplayName>$_wu_user_x</DisplayName>
            <Group>Administrators</Group>
            <Password><Value>$_wu_pass_x</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$_wu_user_x</Username>
        <Password><Value>$_wu_pass_x</Value><PlainText>true</PlainText></Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Install virtio-win guest tools (qemu-guest-agent + drivers)</Description>
          <CommandLine>cmd /c "for %i in (D E F G H I) do @if exist %i:\virtio-win-guest-tools.exe start /wait %i:\virtio-win-guest-tools.exe /install /passive /norestart"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Install SPICE guest tools (spice-vdagent for viewer auto-resize)</Description>
          <CommandLine>cmd /c "for %i in (D E F G H I) do @if exist %i:\spice-guest-tools.exe start /wait %i:\spice-guest-tools.exe /S"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Ensure the qemu-guest-agent service is running (isolate.sh talks to it)</Description>
          <CommandLine>cmd /c "sc config qemu-ga start= auto &amp; net start qemu-ga"</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XML
}
