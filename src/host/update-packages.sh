#!/bin/sh
# =============================================================================
# host/update-packages.sh   (T-11 / SO-9 — maintien en condition de sécurité)
# -----------------------------------------------------------------------------
# host/update.sh ships new appliance CODE; this ships new PACKAGES — the security
# fixes for the base OS and the guests. Without it, a published vulnerability in
# the host or a guest is never closed and the risk grows mechanically (SO-9, one
# of the two Critical scenarios).
#
# It also emits a Software Bill of Materials (SBOM): the installed-package
# inventory of the host and every reachable guest, timestamped, so a new CVE can
# be matched against what this machine actually runs. The difficulty T-11 names
# is organisational (a named owner + a cadence, e.g. critical <=15d / important
# <=30d per the base standard) — this is the tool that cadence drives; wire it to
# a timer or run it on your review cycle.
#
#   host/update-packages.sh              upgrade host + reachable guests, write SBOM
#   host/update-packages.sh --sbom-only  inventory only; change nothing
#   host/update-packages.sh --host-only  upgrade the host only (skip guests)
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/../lib/common.sh" ]; then . "$HERE/../lib/common.sh"
elif [ -f "$HERE/lib/common.sh" ]; then . "$HERE/lib/common.sh"
else echo "[x] cannot find lib/common.sh"; exit 1; fi
require_root
load_config

MODE="full"
for _a in "$@"; do
  case "$_a" in
    --sbom-only) MODE="sbom" ;;
    --host-only) MODE="host" ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "Unknown argument '$_a' (use --sbom-only or --host-only)." ;;
  esac
done

SBOM_DIR="/var/lib/appliance-sbom"
mkdir -p "$SBOM_DIR" 2>/dev/null || true
SBOM="$SBOM_DIR/sbom-$(date -u '+%Y%m%dT%H%M%SZ').txt"
_sbom() { ( umask 077; printf '%s\n' "$1" >> "$SBOM" ) 2>/dev/null || true; }

# --- host package manager (Alpine apk, with apt/pacman/dnf fallbacks) --------
host_upgrade() {
  step "Host packages"
  if command -v apk >/dev/null 2>&1; then
    run apk update && run apk upgrade --available && ok "host: apk upgrade done." || warn "host: apk upgrade had errors."
  elif command -v apt-get >/dev/null 2>&1; then
    run apt-get update && run apt-get -y dist-upgrade && ok "host: apt upgrade done." || warn "host: apt upgrade had errors."
  elif command -v pacman >/dev/null 2>&1; then
    run pacman -Syu --noconfirm && ok "host: pacman upgrade done." || warn "host: pacman upgrade had errors."
  else
    warn "host: no known package manager (apk/apt/pacman) — skipped."
  fi
}
host_inventory() {
  if command -v apk >/dev/null 2>&1; then apk info -v 2>/dev/null | sort
  elif command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W -f '${Package}=${Version}\n' 2>/dev/null | sort
  elif command -v pacman >/dev/null 2>&1; then pacman -Q 2>/dev/null | sort
  fi
}

# --- guest helper: run one command in a domain via the qemu-guest-agent -------
# Bounded poll; returns the guest command's stdout (may be empty). Best-effort:
# a guest with no agent, or shut off, is skipped — never fatal.
guest_run() {
  _dom="$1"; _cmd="$2"
  _out="$(virsh -q qemu-agent-command "$_dom" \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$_cmd\"],\"capture-output\":true}}" 2>/dev/null)" || return 1
  _pid="$(printf '%s' "$_out" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')"
  [ -n "$_pid" ] || return 1
  _i=0
  while [ "$_i" -lt "${PKG_EXEC_TIMEOUT:-300}" ]; do
    _st="$(virsh -q qemu-agent-command "$_dom" \
      "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$_pid}}" 2>/dev/null)" || return 1
    case "$_st" in *'"exited":true'*|*'"exited": true'*)
      # out-data is base64; decode if present so the SBOM is readable.
      _b64="$(printf '%s' "$_st" | sed -n 's/.*"out-data":"\([^"]*\)".*/\1/p')"
      [ -n "$_b64" ] && printf '%s' "$_b64" | base64 -d 2>/dev/null || true
      return 0 ;;
    esac
    sleep 2; _i=$((_i+2))
  done
  return 1
}

# apt vs pacman inside the guest, chosen from its configured OS family.
guest_upgrade_cmd() { case "$1" in apt) printf 'DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade';; arch) printf 'pacman -Syu --noconfirm';; *) printf 'true';; esac; }
guest_inv_cmd()     { case "$1" in apt) printf 'dpkg-query -W -f=\${Package}=\${Version}\\\\n';; arch) printf 'pacman -Q';; *) printf 'true';; esac; }

# --- run ---------------------------------------------------------------------
_sbom "# Appliance SBOM  $(date -u '+%Y-%m-%dT%H:%M:%SZ')  host=$(hostname 2>/dev/null || echo '?')"
_sbom "## host"
host_inventory | while IFS= read -r _l; do _sbom "$_l"; done

if [ "$MODE" != "sbom" ]; then host_upgrade; fi

if [ "$MODE" = "host" ]; then
  ok "SBOM written: $SBOM (host only)."
  audit_event package-update scope=host mode="$MODE" sbom="$(basename "$SBOM")"
  exit 0
fi

# --- guests ------------------------------------------------------------------
if command -v virsh >/dev/null 2>&1; then
  for _env in $(for_each_enabled_env | awk '{print $1}'); do
    _fam="$(os_family "$(env_val "$_env" OS arch)")"
    case "$_fam" in windows) log "$_env: Windows guest — package MCS is via its own MDM/WSUS, skipped here."; continue;; esac
    step "Guest: $_env ($_fam)"
    if [ "$MODE" != "sbom" ]; then
      if guest_run "$_env" "$(guest_upgrade_cmd "$_fam")" >/dev/null 2>&1; then
        ok "$_env: package upgrade attempted (best-effort via guest agent)."
      else
        warn "$_env: could not upgrade (agent down / guest off / no network) — skipped."
      fi
    fi
    _sbom "## guest:$_env ($_fam)"
    _inv="$(guest_run "$_env" "$(guest_inv_cmd "$_fam")" 2>/dev/null || true)"
    if [ -n "$_inv" ]; then printf '%s\n' "$_inv" | while IFS= read -r _l; do _sbom "$_l"; done
    else _sbom "# (unreachable: agent down or guest off)"; fi
  done
fi

ok "Package maintenance complete. SBOM: $SBOM"
audit_event package-update scope=all mode="$MODE" sbom="$(basename "$SBOM")"
