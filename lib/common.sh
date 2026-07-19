#!/bin/sh
# lib/common.sh
# -----------------------------------------------------------------------------
# Shared helpers sourced by every script. POSIX sh so it also works
# under Alpine's default /bin/sh (busybox ash). Scripts that need bashisms
# set their own shebang; this file avoids them.
# -----------------------------------------------------------------------------

# --- pretty logging ----------------------------------------------------------
# All logging goes to STDERR so functions that return a value via stdout
# (make_seed, resolve_secret, env_* helpers) are never polluted by log output.
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

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

# --- config.env plumbing -----------------------------------------------------
# Every script lives one level under the project root (host/, environments/,
# build/, installer/), so the root is the parent of the calling script's dir.
# config.env and config.env.example live at that root.
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_ENV="$APP_ROOT/config.env"
# Consumed by sourcing scripts (e.g. host/detect-and-install.sh seeds config.env
# from it); shellcheck can't see cross-file use of a sourced library variable.
# shellcheck disable=SC2034
CONFIG_EXAMPLE="$APP_ROOT/config.env.example"

load_config() {
  [ -f "$CONFIG_ENV" ] || die "config.env not found. Run host/detect-and-install.sh first."
  # shellcheck disable=SC1090
  . "$CONFIG_ENV"
}

# set_kv KEY VALUE — idempotently upsert KEY="VALUE" into config.env.
set_kv() {
  key="$1"; val="$2"
  touch "$CONFIG_ENV"
  # remove any existing line for this key, then append the new one.
  grep -v "^${key}=" "$CONFIG_ENV" > "$CONFIG_ENV.tmp" 2>/dev/null || true
  printf '%s="%s"\n' "$key" "$val" >> "$CONFIG_ENV.tmp"
  mv "$CONFIG_ENV.tmp" "$CONFIG_ENV"
  export "$key=$val"
}

# gen_secret — print a strong random secret (base64, ~32 chars).
gen_secret() { openssl rand -base64 24 2>/dev/null | tr -d '\n' || head -c18 /dev/urandom | base64 | tr -d '\n'; }

# resolve_secret KEY — return the value of config var KEY. If it is empty or the
# literal "generate", generate a strong one, persist it to config.env, and record
# it (once) to /root/generated-secrets.txt so the operator can retrieve it.
resolve_secret() {
  _k="$1"; _v="$(eval "printf '%s' \"\${${_k}:-}\"")"
  if [ -z "$_v" ] || [ "$_v" = "generate" ]; then
    _v="$(gen_secret)"
    set_kv "$_k" "$_v"
    umask 077; printf '%s=%s\n' "$_k" "$_v" >> /root/generated-secrets.txt 2>/dev/null || true
    warn "Generated $_k -> saved to /root/generated-secrets.txt (record it): $_v"
  fi
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
for_each_enabled_env() {
  _i=0
  for _e in $ENVS; do
    _i=$((_i+1))
    [ "$(env_val "$_e" ENABLED 1)" != "0" ] && printf '%s %s\n' "$_e" "$_i"
  done
}
# Derived, stable per-env attributes (by name/index).
env_net()    { printf 'isol-%s' "$1"; }             # libvirt network name
env_bridge() { printf 'virbr%s' "$2"; }             # bridge iface (<=15 chars)
env_subnet() { printf '%s.%s' "${SUBNET_BASE:-10.10}" "$2"; }  # /24 third octet = index
# OS -> base image / os-variant / download URL.
os_base()    { case "$1" in ubuntu) printf '%s/base-ubuntu.img' "$IMAGES_DIR";; arch) printf '%s/base-arch.qcow2' "$IMAGES_DIR";; debian) printf '%s/base-debian.qcow2' "$IMAGES_DIR";; *) return 1;; esac; }
os_variant() { case "$1" in ubuntu) printf '%s' "${UBUNTU_OS_VARIANT:-ubuntu22.04}";; arch) printf '%s' "${ARCH_OS_VARIANT:-archlinux}";; debian) printf '%s' "${DEBIAN_OS_VARIANT:-debian12}";; esac; }
# os_family: apt-based (ubuntu/debian) vs arch. Drives cloud-init package steps.
os_family()  { case "$1" in ubuntu|debian) printf 'apt';; arch) printf 'arch';; *) printf 'apt';; esac; }
# Upper-case an env name for trust-bar labels (office -> OFFICE). Portable.
env_title() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
