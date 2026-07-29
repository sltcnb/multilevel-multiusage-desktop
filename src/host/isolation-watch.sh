#!/bin/sh
# =============================================================================
# host/isolation-watch.sh
# -----------------------------------------------------------------------------
# Continuous assurance that the environments are STILL isolated.
#
# environments/isolate.sh proves isolation once, at setup, and exits. After that
# nothing ever looks again: a ruleset can be flushed, a libvirt network
# redefined, a script half re-run — and the machine keeps presenting three
# environments that no longer have a fence between them. This is the recurring
# check. It recomputes the ordered environment pairs from $ENVS, asserts every
# one of them still has a live DROP rule in the kernel, and publishes the
# verdict so "is it still isolated?" can be answered at any instant instead of
# only by re-running setup and reading the output.
#
# Host-side only, no guest agent: isolate.sh section 3b already establishes that
# the ruleset assertion alone is conclusive for the cross-environment fence, and
# it costs milliseconds — cheap enough to run every minute, and it works while
# the guests are still booting or powered off.
#
#   host/isolation-watch.sh [--once] [-v]   run one check (--once is the default)
#   host/isolation-watch.sh --install-timer install/refresh the recurring check
#
# Exit status: 0 = OK, 1 = FAIL (isolation is broken), 2 = UNKNOWN (could not
# determine — treat as "nobody can currently vouch for this machine").
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

# CONTRACT A: tmpfs status file, one TAB-separated line "STATE EPOCH DETAIL".
STATUS_DIR="/run/appliance"
STATUS_FILE="$STATUS_DIR/isolation.status"
# The lock lives beside it on the same tmpfs, so a lock can never survive a
# reboot and wedge the watch on a machine that came back up.
LOCK_DIR="$STATUS_DIR/isolation-watch.lock"
# CONTRACT B: append-only audit log, 0600 root:root.
AUDIT_LOG="/var/log/appliance-audit.log"

MODE="once"
VERBOSE=0
# A human at a console expects an answer; cron does not. Being chatty by default
# would put a line a minute into the appliance's logs and drown the one that
# matters, so the steady-state OK is silent unless someone is watching.
if [ -t 2 ]; then VERBOSE=1; fi

for _arg in "$@"; do
  case "$_arg" in
    --once)          MODE="once" ;;
    --install-timer) MODE="install-timer" ;;
    -v|--verbose)    VERBOSE=1 ;;
    -h|--help)
      sed -n '3,24p' "$0" >&2; exit 0 ;;
    *) die "Unknown argument '$_arg' (use --once, --install-timer, -v)." ;;
  esac
done

LOCK_HELD=0
CHECKING=0
EMITTED=0

# --- CONTRACT A -------------------------------------------------------------
# Atomic write: a reader (the trust bar, an operator, a later health endpoint)
# must never catch a half-written line, and two watchers must never interleave
# their bytes. Temp file + rename inside the same tmpfs directory guarantees a
# reader sees either the old line or the new one, never a splice of both.
write_status() {
  _st="$1"
  # DETAIL is one line by contract; fold anything that could break the format.
  _dt="$(printf '%s' "$2" | tr '\n\t' '  ')"
  mkdir -p "$STATUS_DIR" 2>/dev/null || true
  _tmp="$STATUS_FILE.$$"
  if printf '%s\t%s\t%s\n' "$_st" "$(date +%s)" "$_dt" > "$_tmp" 2>/dev/null; then
    chmod 644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$_tmp"
  fi
  EMITTED=1
}

# CONTRACT A also binds readers: a missing or unparsable file is UNKNOWN and
# must never crash the reader. This script is one of its own readers — it needs
# the previous verdict to decide whether the state CHANGED — so it obeys the
# same rule. After a reboot /run is a fresh tmpfs and the file is simply gone,
# which is exactly what we want: UNKNOWN until the first check of this boot,
# never a stale OK inherited from the last one.
prev_state() {
  _s=""
  if [ -r "$STATUS_FILE" ]; then
    _s="$(head -n1 "$STATUS_FILE" 2>/dev/null | cut -f1)" || _s=""
  fi
  case "$_s" in
    OK|FAIL|UNKNOWN) printf '%s' "$_s" ;;
    *)               printf 'UNKNOWN' ;;
  esac
}

# --- CONTRACT B -------------------------------------------------------------
# One event per line, "<ISO8601-UTC> <event> <key=value>...". A short line
# written with a single append to an O_APPEND descriptor is atomic, so parallel
# writers (this watch, the switcher, the USB router) cannot tear each other's
# lines. Values are space-free tokens by construction and never carry a secret.
audit() {
  ( umask 077; touch "$AUDIT_LOG" ) 2>/dev/null || true
  # Self-heal the mode: this log names which environment lost its fence and
  # when. The unprivileged kiosk desktop user must not be able to read it, and
  # certainly not to append a reassuring forgery.
  chmod 600 "$AUDIT_LOG" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$AUDIT_LOG" 2>/dev/null || true
}

# record STATE DETAIL [KEY=VALUE ...] — publish CONTRACT A always, append
# CONTRACT B only when the STATE actually changed. Running once a minute, an
# unconditional append would bury the single line that matters (the transition)
# under 1440 identical lines a day.
record() {
  _st="$1"; _dt="$2"; shift 2
  _prev="$(prev_state)"
  write_status "$_st" "$_dt"
  if [ "$_st" != "$_prev" ]; then
    if [ "$#" -gt 0 ]; then
      audit "isolation-check state=$_st prev=$_prev $*"
    else
      audit "isolation-check state=$_st prev=$_prev"
    fi
  fi
}

# --- concurrency -------------------------------------------------------------
# The cron tick and an operator typing the command can land at the same instant.
# Both would read-previous-then-write-new and could log the same transition
# twice. mkdir is atomic on every filesystem we care about and needs no flock
# (busybox has no flock built in).
acquire_lock() {
  # mkdir is not recursive: on a fresh boot /run/appliance does not exist yet,
  # and without its parent the lock can never be taken — the first check of
  # every boot would report "another check is running" and exit UNKNOWN.
  mkdir -p "$STATUS_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then return 0; fi
  # Reap a lock left by an instance that was killed outright: without this the
  # watch wedges forever and the status file freezes at whatever it last said —
  # very likely a stale OK, which is the precise failure this script exists to
  # prevent. Failing open on the lock is safe; failing open on the verdict isn't.
  _now="$(date +%s)"
  _born="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || printf '%s' "$_now")"
  if [ "$((_now - _born))" -gt "${ISOLATION_WATCH_LOCK_STALE:-300}" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then return 0; fi
  fi
  return 1
}

cleanup() {
  _rc=$?
  if [ "$LOCK_HELD" = "1" ]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
  # Fail closed. If we got as far as starting a check but never reached a
  # verdict (nft missing, config unreadable, killed mid-run), the status file
  # must not be left asserting the previous run's OK. UNKNOWN is the honest
  # answer and readers already know how to treat it.
  if [ "$CHECKING" = "1" ] && [ "$EMITTED" = "0" ]; then
    record UNKNOWN "check aborted before a verdict (rc=$_rc)" "reason=aborted"
  fi
  return 0
}
trap cleanup EXIT

# The pair grep is the security-critical comparison in this script: anchor it on
# literal addresses so a dot cannot wildcard 10.10.1.0 onto a lookalike subnet.
esc_re() { printf '%s' "$1" | sed 's/[.]/\\./g'; }

# -----------------------------------------------------------------------------
# The check.
# -----------------------------------------------------------------------------
run_check() {
  if ! acquire_lock; then
    # Another check is already in flight; its verdict will be at least as fresh
    # as ours. Report what is on file rather than racing it into the audit log.
    _s="$(prev_state)"
    if [ "$VERBOSE" = "1" ]; then log "another isolation check is running; last recorded state: $_s"; fi
    case "$_s" in OK) exit 0 ;; FAIL) exit 1 ;; *) exit 2 ;; esac
  fi
  LOCK_HELD=1
  CHECKING=1
  require_cmds nft

  # ALL defined environment positions, enabled or not — the same superset
  # isolate.sh builds its DROP rules over, and for the same reason: an
  # environment that was created and then disabled keeps its libvirt network and
  # possibly a running VM, so it must stay fenced. Checking only the enabled
  # ones would call that machine isolated when it is not.
  _pos=""; _n=0
  for _e in ${ENVS:-}; do
    _n=$((_n + 1))
    _pos="$_pos $_e:$_n"
  done
  _total=$((_n * (_n - 1)))

  if [ "$_n" -eq 0 ]; then
    # No environment model at all — we cannot say anything about isolation, and
    # "nothing to check" must never be reported as OK.
    record UNKNOWN "ENVS is empty — no environment model to verify" "reason=no-envs"
    warn "ENVS is empty in config.env — isolation cannot be verified."
    exit 2
  fi

  # THE failure mode this watch exists for. With the table gone there are no
  # DROP rules to look for, and a pair loop over an absent table would count
  # zero present out of zero expected and cheerfully report OK on a wide-open
  # machine. Assert the table exists BEFORE looking at any pair.
  if ! _live="$(nft list table inet appliance_isol 2>/dev/null)"; then
    record FAIL "nftables table inet appliance_isol is absent (ruleset flushed?)" \
                "pairs=0/$_total missing=table"
    warn "Isolation table inet appliance_isol is GONE — run ./src/environments/isolate.sh."
    exit 1
  fi

  _present=0; _missing=0; _first=""; _list=""
  for _a in $_pos; do
    _ea="${_a%:*}"; _ia="${_a#*:}"
    _ra="$(esc_re "$(env_subnet "$_ea" "$_ia").0/24")"
    for _b in $_pos; do
      [ "$_a" = "$_b" ] && continue
      _eb="${_b%:*}"; _ib="${_b#*:}"
      _rb="$(esc_re "$(env_subnet "$_eb" "$_ib").0/24")"
      if printf '%s\n' "$_live" | grep -q "ip saddr $_ra ip daddr $_rb .*drop"; then
        _present=$((_present + 1))
      else
        _missing=$((_missing + 1))
        [ -n "$_first" ] || _first="$_ea->$_eb"
        # Keep DETAIL to one readable line even when the whole fence is gone.
        if [ "$_missing" -le 4 ]; then _list="$_list $_ea->$_eb"; fi
      fi
    done
  done

  if [ "$_missing" -eq 0 ]; then
    record OK "$_present/$_total pairs" "pairs=$_present/$_total"
    if [ "$VERBOSE" = "1" ]; then ok "Isolation intact: $_present/$_total inter-env DROP rules live."; fi
    exit 0
  fi

  if [ "$_missing" -gt 4 ]; then _list="$_list (+$((_missing - 4)) more)"; fi
  record FAIL "$_present/$_total pairs; missing$_list" "pairs=$_present/$_total missing=$_first"
  # Worth stderr even unattended: on the appliance this is the first place an
  # operator looks after a boot that went wrong.
  warn "Isolation INCOMPLETE: $_missing/$_total inter-env DROP rule(s) missing —$_list"
  exit 1
}

# -----------------------------------------------------------------------------
# Timer installation.
#
# WHY cron on the appliance: OpenRC has no timer concept, and a supervised
# sleep-loop daemon would mean owning a PID file, restart policy and log
# rotation for a check that takes milliseconds. busybox crond is already on the
# box, already supervised by OpenRC, and re-reads /etc/crontabs every minute, so
# one crontab line is the entire mechanism — nothing to keep alive, nothing to
# leak. Its granularity is one minute, which is why the default interval is 60s;
# a shorter interval is rounded up to a minute there. On a systemd host (the
# Debian development path) we emit a real timer instead, which does honour
# sub-minute intervals.
#
# Both writers are idempotent: they remove whatever they installed before and
# put back exactly one entry, so re-running after an interval or path change
# leaves a single correct schedule rather than a second one alongside the first.
# -----------------------------------------------------------------------------
CRONTAB="/etc/crontabs/root"
SD_SERVICE="/etc/systemd/system/appliance-isolation-watch.service"
SD_TIMER="/etc/systemd/system/appliance-isolation-watch.timer"

remove_timer() {
  if [ -f "$CRONTAB" ] && grep -q 'isolation-watch\.sh' "$CRONTAB" 2>/dev/null; then
    _t="$CRONTAB.appliance.$$"
    ( umask 077; grep -v 'isolation-watch\.sh' "$CRONTAB" > "$_t" || true )
    mv -f "$_t" "$CRONTAB"
  fi
  if command -v systemctl >/dev/null 2>&1 && [ -f "$SD_TIMER" ]; then
    systemctl disable --now appliance-isolation-watch.timer 2>/dev/null || true
    rm -f "$SD_TIMER" "$SD_SERVICE"
    systemctl daemon-reload 2>/dev/null || true
  fi
}

install_timer() {
  _self="$HERE/isolation-watch.sh"
  _iv="${ISOLATION_WATCH_INTERVAL:-60}"
  case "$_iv" in
    ''|*[!0-9]*) die "ISOLATION_WATCH_INTERVAL must be a whole number of seconds (got '$_iv')." ;;
  esac
  [ "$_iv" -ge 1 ] || die "ISOLATION_WATCH_INTERVAL must be at least 1 second."

  if [ "${ISOLATION_WATCH:-1}" = "0" ]; then
    remove_timer
    warn "ISOLATION_WATCH=0 — recurring isolation check NOT installed. Nothing will notice if the ruleset is flushed after setup."
    return 0
  fi

  # OpenRC first, matching every other service-touching script in this tree.
  if command -v rc-update >/dev/null 2>&1; then
    _min=$(( (_iv + 59) / 60 ))
    if [ "$_min" -lt 1 ];  then _min=1;  fi
    # "*/60" is not a legal minute field; an hour is cron's practical floor here.
    if [ "$_min" -gt 59 ]; then _min=59; fi
    if [ "$_min" -eq 1 ]; then _spec="* * * * *"; else _spec="*/$_min * * * *"; fi

    mkdir -p /etc/crontabs
    ( umask 077; touch "$CRONTAB" )
    _t="$CRONTAB.appliance.$$"
    # The check's output IS the status file and the audit log, so send the
    # stream to /dev/null: crond would otherwise mail or syslog a line a minute.
    ( umask 077
      grep -v 'isolation-watch\.sh' "$CRONTAB" > "$_t" 2>/dev/null || true
      printf '%s %s --once >/dev/null 2>&1\n' "$_spec" "$_self" >> "$_t" )
    chmod 600 "$_t"
    mv -f "$_t" "$CRONTAB"
    rc-update add crond default 2>/dev/null || true
    rc-service crond start >/dev/null 2>&1 || true
    ok "Recurring isolation check installed (crond, every ${_min} min) -> $STATUS_FILE"
    if [ "$_iv" -lt 60 ]; then
      warn "ISOLATION_WATCH_INTERVAL=${_iv}s rounded up to 60s: cron cannot schedule below one minute."
    fi
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system
    # Write through a temp file in the same directory so a concurrent
    # daemon-reload can never read a half-written unit.
    _t="$(mktemp /etc/systemd/system/.appliance-watch.XXXXXX)"
    cat > "$_t" <<EOF
[Unit]
Description=Verify inter-environment isolation is still enforced (appliance)

[Service]
Type=oneshot
ExecStart=$_self --once
EOF
    chmod 644 "$_t"; mv -f "$_t" "$SD_SERVICE"
    _t="$(mktemp /etc/systemd/system/.appliance-watch.XXXXXX)"
    cat > "$_t" <<EOF
[Unit]
Description=Periodic inter-environment isolation check (appliance)

[Timer]
OnBootSec=30s
OnUnitActiveSec=${_iv}s
AccuracySec=1s
Unit=appliance-isolation-watch.service

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$_t"; mv -f "$_t" "$SD_TIMER"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now appliance-isolation-watch.timer 2>/dev/null || true
    ok "Recurring isolation check installed (systemd timer, every ${_iv}s) -> $STATUS_FILE"
    return 0
  fi

  warn "Neither OpenRC nor systemd found — no recurring isolation check installed. Run host/isolation-watch.sh --once from your own scheduler, or isolation is only ever verified at setup time."
}

require_root
load_config

case "$MODE" in
  install-timer) install_timer ;;
  *)             run_check ;;
esac
