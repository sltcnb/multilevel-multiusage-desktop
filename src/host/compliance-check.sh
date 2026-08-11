#!/bin/sh
# =============================================================================
# host/compliance-check.sh   (T-17 / SO-12 — post-install conformity gate)
# -----------------------------------------------------------------------------
# The provisioning sequence deliberately does NOT abort a machine mid-setup: a
# half-provisioned appliance is easier to finish than to rebuild. That choice is
# defensible, but it means a machine can reach the desktop with a step silently
# skipped — no isolation table, seeds never ejected, secrets never scrubbed —
# and nothing tells the operator. This is that missing control: it verifies, from
# the host and read-only, that the security-relevant provisioning steps actually
# took effect, publishes a verdict where anything can read it, and exits non-zero
# when the machine is NOT fit for use so a boot hook / CI / operator can gate on
# it (see --gate below).
#
#   host/compliance-check.sh            run the checks, print + publish a verdict
#   host/compliance-check.sh --gate     same, but ALSO drop a boot-blocking marker
#                                        on failure (and remove it on success)
#   host/compliance-check.sh -v         verbose (show every passing check too)
#
# Exit: 0 = COMPLIANT, 1 = NON-COMPLIANT (a required step did not take), 2 =
# UNKNOWN (could not evaluate — e.g. run before setup, or virsh/nft missing).
# Read-only: it inspects state, it never changes the machine (except the marker
# under --gate, which lives in tmpfs and only ever reflects the latest verdict).
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config

VERBOSE=0; GATE=0
for _a in "$@"; do
  case "$_a" in
    --gate) GATE=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "Unknown argument '$_a' (use --gate, -v)." ;;
  esac
done

# CONTRACT A (shared with isolation-watch): tmpfs status file, one TAB-separated
# line "STATE EPOCH DETAIL". Lives in /run so a stale verdict never survives a
# reboot — after a boot the honest answer is "re-checked", never a cached PASS.
STATUS_DIR="/run/appliance"
STATUS_FILE="$STATUS_DIR/compliance.status"
GATE_MARKER="$STATUS_DIR/NONCOMPLIANT"      # present == last verdict was FAIL

PASS=0; FAILN=0; WARN=0
_ok()   { PASS=$((PASS+1));  [ "$VERBOSE" = 1 ] && ok   "$1" || true; }
_fail() { FAILN=$((FAILN+1)); warn "NON-COMPLIANT: $1"; }
_warn() { WARN=$((WARN+1));  warn "advisory: $1"; }

# --- 1. Every ENABLED env has a defined, autostart domain --------------------
# NB: `for X in $(...)` runs its body in the CURRENT shell (unlike `... | while`),
# so the _ok/_fail counters below are mutated here, not lost in a subshell.
require_cmds virsh
_defined="$(virsh list --all --name 2>/dev/null || true)"
for env in $(for_each_enabled_env | awk '{print $1}'); do
  if printf '%s\n' "$_defined" | grep -qx "$env"; then
    if virsh dominfo "$env" 2>/dev/null | grep -qi '^Autostart:.*enable'; then
      _ok "domain '$env' defined + autostart"
    else
      _fail "domain '$env' is defined but autostart is OFF (won't come up on boot)"
    fi
  else
    _fail "enabled env '$env' has no libvirt domain (create.sh did not run for it)"
  fi
done

# --- 2. Inter-env isolation table is loaded ----------------------------------
if command -v nft >/dev/null 2>&1; then
  if nft list table inet appliance_isol >/dev/null 2>&1 \
     && nft list table inet appliance_isol 2>/dev/null | grep -q 'drop'; then
    _ok "isolation table inet appliance_isol present with drop rules"
  else
    _fail "isolation table inet appliance_isol missing or has no drop rules (isolate.sh did not run)"
  fi
else
  _warn "nft not available — cannot verify the isolation table"
fi

# --- 3. Provisioning seeds ejected (T-02): no plaintext-secret media attached -
_seed_left=0
for env in $(for_each_enabled_env | awk '{print $1}'); do
  if virsh domblklist "$env" 2>/dev/null | awk '{print $NF}' | grep -qE '\-(seed|unattend)\.iso$'; then
    _fail "env '$env' still has a provisioning ISO attached (seed not ejected — plaintext password exposed)"
    _seed_left=$((_seed_left+1))
  fi
done
[ "$_seed_left" = 0 ] && _ok "no provisioning seed/unattend ISO attached to any domain"

# --- 4. Operational secrets scrubbed from config.env (advisory) --------------
# scrub-secrets.sh is the documented LAST step and is optional, so a still-set
# password is a warning, not a hard fail — but a fielded machine should have run
# it. (config.env is 0600; we only test emptiness, never print the value.)
if grep -q '^GUEST_PASSWORD=""' "$CONFIG_ENV" 2>/dev/null; then
  _ok "GUEST_PASSWORD scrubbed from config.env"
else
  _warn "GUEST_PASSWORD still present in config.env — run scrub-secrets.sh once provisioning is confirmed"
fi

# --- 5. Kiosk libvirt access is confined (T-03) ------------------------------
if [ -f /etc/libvirt/libvirtd.conf ] \
   && grep -q '^auth_unix_rw *= *"none"' /etc/libvirt/libvirtd.conf 2>/dev/null; then
  _warn "libvirt auth_unix_rw=none — kiosk has unconfined (root-equivalent) libvirt access (T-03 not in effect on this host)"
else
  _ok "libvirt kiosk access is not the unconfined auth_unix_rw=none"
fi

# --- 6. Continuous isolation verdict is not FAIL -----------------------------
if [ -r "$STATUS_DIR/isolation.status" ]; then
  _istate="$(cut -f1 "$STATUS_DIR/isolation.status" 2>/dev/null || echo UNKNOWN)"
  case "$_istate" in
    OK)      _ok "continuous isolation watch reports OK" ;;
    FAIL)    _fail "continuous isolation watch reports FAIL (isolation is currently broken)" ;;
    *)       _warn "isolation watch verdict is '$_istate' (not yet verified this boot)" ;;
  esac
else
  _warn "no isolation-watch verdict yet (run isolate.sh / isolation-watch.sh --once)"
fi

# --- Verdict -----------------------------------------------------------------
mkdir -p "$STATUS_DIR" 2>/dev/null || true
if [ "$FAILN" -gt 0 ]; then
  STATE="NON-COMPLIANT"; RC=1
elif [ "$PASS" -eq 0 ]; then
  STATE="UNKNOWN"; RC=2
else
  STATE="COMPLIANT"; RC=0
fi
_detail="pass=$PASS fail=$FAILN warn=$WARN"
_tmp="$STATUS_FILE.$$"
if ( umask 022; printf '%s\t%s\t%s\n' "$STATE" "$(date -u +%s)" "$_detail" > "$_tmp" ) 2>/dev/null; then
  mv -f "$_tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$_tmp"
fi
audit_event compliance-check state="$STATE" "$_detail"

# --gate: publish a boot-blocking marker so a desktop-start hook can refuse to
# bring the kiosk up on a non-compliant machine. tmpfs, so it never persists a
# stale block across a reboot; removed the moment a run passes.
if [ "$GATE" = 1 ]; then
  if [ "$RC" = 1 ]; then
    ( umask 022; printf '%s\t%s\n' "$(date -u +%s)" "$_detail" > "$GATE_MARKER" ) 2>/dev/null || true
  else
    rm -f "$GATE_MARKER" 2>/dev/null || true
  fi
fi

printf '\nCompliance: %s  (%s)\n' "$STATE" "$_detail" >&2
case "$RC" in
  0) ok  "Appliance is COMPLIANT — all required provisioning steps took effect." ;;
  1) warn "Appliance is NON-COMPLIANT — $FAILN required step(s) did not take. Do not put this machine into service until fixed (see the lines above)." ;;
  2) warn "Compliance UNKNOWN — nothing to evaluate yet (run this after setup-machine.sh steps 1-2)." ;;
esac
exit "$RC"
