#!/bin/bash
# =============================================================================
# environments/diode.sh — ANSSI-PA-114 §3.18 file diodes between user domains
# -----------------------------------------------------------------------------
# PA-114 §3.18: "Les communications entre domaines utilisateurs sont proscrites."
# The appliance enforces exactly that by default (environments/isolate.sh drops
# every ordered pair of env subnets). §3.18 then permits ONE narrow exception,
# and only if file exchange "est nécessaire et autorisé": a DIODE — a
# unidirectional, mediated, logged transfer of FILES between two IDENTIFIED user
# domains. This script is that diode, and nothing else.
#
# Why this cannot be a firewall hole. §3.18's warning is explicit: the diode
# "ne doit pas pouvoir être utilisé pour créer un canal de communication non
# surveillé d'un domaine utilisateur à un autre." A one-way nftables allow
# between two guest subnets is precisely that forbidden channel (and a stateful
# TCP allow is not even one-way at the data layer). So the diode NEVER touches
# the guest network: the isolation ruleset stays a total all-pairs DROP, and the
# only thing that ever bridges two domains is the SOCLE, moving bytes it has read
# and inspected, over each guest's qemu-guest-agent virtio-serial channel. The
# two user domains have no path to each other at any layer — the host is the
# diode, and the diode only carries files the operator explicitly accepted.
#
# How the §3.18 properties map here:
#   §3.18.1 files only ....... guest-file-read/write moves file bytes, no socket.
#   §3.18.2 unidirectional,
#           two identified
#           domains .......... only the SRC>DST pairs listed in $DIODES flow, in
#                              that direction; an unlisted or reversed pair is
#                              refused (fail closed).
#   §3.18.3 explicit export
#           in the source .... the user drops files into the source VM's outbox
#                              (<base>/<DIODE_OUTBOX>/<dst>/); nothing is pulled
#                              that the user did not place there.
#   §3.18.4 acceptance via a
#           GUI in a support
#           domain ........... the accept/refuse prompt runs on the SOCLE (the
#                              kiosk surface — outside every user domain), one
#                              file at a time. Default interactive; --yes only
#                              for the udev/automation path and the tests.
#   §3.18.5 log every transfer
#           in the socle's
#           logging domain ... audit_event diode-transfer ... to the appliance
#                              audit log: file name, sha256, byte count, the
#                              direction, the decision and (on refusal) why.
#   §3.18.6/.7 optional file
#           vetting in a
#           dedicated support
#           domain ........... DIODE_SCAN runs a pattern deny-list and (if
#                              present) clamav on the host copy before delivery.
#                              §3.18.7's stricter "dedicated support domain per
#                              diode, unprivileged" is a documented hardening
#                              step (DIODE_SCAN_VM); see README.
#
# Usage:
#   diode.sh                 process every configured diode (interactive accept)
#   diode.sh --list          show what is pending in each diode, transfer nothing
#   diode.sh --pair a>b      process only that one diode
#   diode.sh --yes           accept every pending file without prompting
#                            (udev/automation; NOT the default — §3.18.4 wants a
#                            human in the loop)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
export LIBVIRT_DEFAULT_URI=qemu:///system
# Root: the diode reads config.env (mode 0600 — it names the domains authorized
# to exchange), writes the audit record, and drives the guest agents. The
# acceptance prompt therefore runs on the socle's root console (tty2 /
# setup-machine.sh step 11) — a support surface outside every user domain, which
# is exactly where §3.18.4 wants the human in the loop.
require_root
require_cmds virsh base64 sha256sum dd
load_config
# Provision the audit log up front: §3.18.5 makes the transfer record part of the
# control, so a diode that cannot be logged is a diode that must not run silently.
audit_init

MODE="run"        # run | list
ONLY_PAIR=""      # restrict to one SRC>DST
ASSUME_YES=0      # --yes: skip the §3.18.4 prompt (automation only)
while [ $# -gt 0 ]; do
  case "$1" in
    --list)  MODE="list" ;;
    --yes|-y) ASSUME_YES=1 ;;
    --pair)  ONLY_PAIR="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# Config + defaults.
#   DIODES              space-separated SRC>DST pairs, e.g.
#                       "administration>development administration>office development>office"
#   DIODE_MAX_BYTES     per-file ceiling (default 8 MiB). A diode moves documents,
#                       not disk images; a size cap is also the cheapest guard
#                       against a compromised source trying to drain data.
#   DIODE_SCAN          1 = run the §3.18.6 vetting (deny-list + clamav) before
#                       delivery; a hit refuses the file.
#   DIODE_SCAN_DENYLIST space-separated egrep patterns; any match refuses.
#   DIODE_OUTBOX/INBOX  directory names inside the guests.
#   <env>_DIODE_DIR     per-env base dir override (default /home/$GUEST_USER);
#                       a non-Linux guest (e.g. a Windows office VM) sets its own.
# -----------------------------------------------------------------------------
DIODES="${DIODES:-}"
DIODE_MAX_BYTES="${DIODE_MAX_BYTES:-8388608}"
DIODE_SCAN="${DIODE_SCAN:-0}"
DIODE_SCAN_DENYLIST="${DIODE_SCAN_DENYLIST:-}"
DIODE_OUTBOX="${DIODE_OUTBOX:-diode-out}"
DIODE_INBOX="${DIODE_INBOX:-diode-in}"
GUEST_USER="${GUEST_USER:-operator}"

if [ -z "$DIODES" ]; then
  log "No diodes configured (DIODES is empty). Inter-domain exchange stays fully"
  log "blocked, which is the PA-114 default — nothing to do."
  exit 0
fi

# diode_base ENV -> the guest-side base dir that holds the diode outbox/inbox.
diode_base() {
  _b="$(env_val "$1" DIODE_DIR)"
  [ -n "$_b" ] || _b="/home/$GUEST_USER"
  printf '%s' "$_b"
}

# -----------------------------------------------------------------------------
# qemu-guest-agent transport. The host talks to each guest ONLY over its agent
# channel — never the network — so moving a file between two domains never opens
# a path between the domains themselves.
# -----------------------------------------------------------------------------
# ga <domain> <json> -> raw agent response on stdout; non-zero if the agent is
# unreachable. Quiet: callers decide what a failure means.
ga() { virsh -q qemu-agent-command "$1" "$2" 2>/dev/null; }

# ga_exec <domain> <shell-command> -> runs the command in the guest via
# guest-exec, polling to completion. Sets GA_RC (in-guest exit code) and GA_OUT
# (decoded stdout). Returns 0 if it ran, 1 if the agent never answered / timed
# out. Mirrors isolate.sh's poll-don't-sleep approach so a slow guest degrades
# to a clean timeout rather than a wrong answer.
GA_RC=""; GA_OUT=""
ga_exec() {
  _dom="$1"; _cmd="$2"; GA_RC=""; GA_OUT=""
  # The command is embedded in JSON inside a shell -c string. Every path we pass
  # is built from config + a filename we have already validated to a safe
  # charset (no quotes, backslashes or spaces), so this interpolation cannot be
  # broken out of. Do not relax the filename validation below.
  _open="$(ga "$_dom" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$_cmd\"],\"capture-output\":true}}")" || return 1
  _pid="$(printf '%s' "$_open" | sed -n 's/.*"pid":[[:space:]]*\([0-9]*\).*/\1/p')"
  [ -n "$_pid" ] || return 1
  _i=0
  while [ "$_i" -lt "${GUEST_EXEC_TIMEOUT:-20}" ]; do
    _st="$(ga "$_dom" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$_pid}}")" || return 1
    case "$_st" in
      *'"exited":true'*|*'"exited": true'*)
        GA_RC="$(printf '%s' "$_st" | sed -n 's/.*"exitcode":[[:space:]]*\([0-9]*\).*/\1/p')"
        _b64="$(printf '%s' "$_st" | sed -n 's/.*"out-data":"\([^"]*\)".*/\1/p')"
        [ -z "$_b64" ] || GA_OUT="$(printf '%s' "$_b64" | base64 -d 2>/dev/null || true)"
        [ -n "$GA_RC" ] || GA_RC=0
        return 0 ;;
    esac
    sleep 1; _i=$((_i+1))
  done
  return 1
}

# gf_read <domain> <guest-path> <host-dest> <max-bytes> -> pull a guest file to a
# host temp file, in base64 chunks over guest-file-read. Returns 2 if the file
# grows past max-bytes (delivery refused), 1 on any agent error, 0 on success.
gf_read() {
  _dom="$1"; _path="$2"; _dest="$3"; _max="$4"
  _o="$(ga "$_dom" "{\"execute\":\"guest-file-open\",\"arguments\":{\"path\":\"$_path\",\"mode\":\"r\"}}")" || return 1
  _h="$(printf '%s' "$_o" | sed -n 's/.*"return":[[:space:]]*\([0-9]*\).*/\1/p')"
  [ -n "$_h" ] || return 1
  : > "$_dest"; _total=0; _rc=0
  # Bound the loop: (max / chunk) reads should suffice, plus slack. A guest agent
  # that keeps returning data-less, non-EOF responses cannot spin the host here.
  _cap=$(( _max / 49152 + 16 )); _n=0
  while :; do
    _n=$((_n+1)); [ "$_n" -le "$_cap" ] || { _rc=1; break; }
    _r="$(ga "$_dom" "{\"execute\":\"guest-file-read\",\"arguments\":{\"handle\":$_h,\"count\":49152}}")" || { _rc=1; break; }
    _buf="$(printf '%s' "$_r" | sed -n 's/.*"buf-b64":"\([^"]*\)".*/\1/p')"
    if [ -n "$_buf" ]; then
      printf '%s' "$_buf" | base64 -d >> "$_dest" 2>/dev/null || { _rc=1; break; }
      _total="$(_filesize "$_dest")"
      if [ "$_total" -gt "$_max" ] 2>/dev/null; then _rc=2; break; fi
    fi
    case "$_r" in *'"eof":true'*|*'"eof": true'*) break ;; esac
  done
  ga "$_dom" "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":$_h}}" >/dev/null 2>&1 || true
  return "$_rc"
}

# gf_write <domain> <guest-path> <host-src> -> push a host file into the guest, in
# independently-decodable base64 chunks (each chunk is whole raw bytes -> its own
# base64, so writes never straddle a base64 quantum). Returns 0/1.
gf_write() {
  _dom="$1"; _path="$2"; _src="$3"
  _o="$(ga "$_dom" "{\"execute\":\"guest-file-open\",\"arguments\":{\"path\":\"$_path\",\"mode\":\"w\"}}")" || return 1
  _h="$(printf '%s' "$_o" | sed -n 's/.*"return":[[:space:]]*\([0-9]*\).*/\1/p')"
  [ -n "$_h" ] || return 1
  _off=0; _rc=0; _chunk="$(mktemp)"
  while :; do
    # 48000 is a multiple of 3, so each raw chunk base64-encodes with no '='
    # padding until the final short chunk — every write is self-contained.
    dd if="$_src" of="$_chunk" bs=48000 skip="$_off" count=1 2>/dev/null
    _n="$(_filesize "$_chunk")"
    [ "$_n" -gt 0 ] 2>/dev/null || break
    _b64="$(base64 < "$_chunk" | tr -d '\n')"
    ga "$_dom" "{\"execute\":\"guest-file-write\",\"arguments\":{\"handle\":$_h,\"buf-b64\":\"$_b64\"}}" >/dev/null 2>&1 || { _rc=1; break; }
    _off=$((_off+1))
  done
  rm -f "$_chunk"
  ga "$_dom" "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":$_h}}" >/dev/null 2>&1 || true
  return "$_rc"
}

_filesize() { stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || printf '0'; }

# safe_name NAME -> 0 if NAME is a single, safe path component. A diode file name
# comes from a user domain that may be compromised, and we interpolate it into a
# guest shell command and a JSON string, so anything but a conservative charset
# is rejected (and logged as a refusal per §3.18.5). No '/', no leading '-', no
# '.'/'..', bounded length, printable set only.
safe_name() {
  case "$1" in
    ""|.|..) return 1 ;;
    -*|*/*)  return 1 ;;
  esac
  [ "${#1}" -le 128 ] || return 1
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# -----------------------------------------------------------------------------
# §3.18.6 vetting. Runs on the host copy BEFORE the file is ever written into the
# destination domain. Returns 0 = clean, 1 = refuse (SCAN_REASON is set).
# This is the pragmatic host-side form; §3.18.7's dedicated per-diode support
# domain (DIODE_SCAN_VM) is a documented stricter option — see README.
# -----------------------------------------------------------------------------
SCAN_REASON=""
scan_file() {
  SCAN_REASON=""
  [ "$DIODE_SCAN" = "1" ] || return 0
  _f="$1"
  for _pat in $DIODE_SCAN_DENYLIST; do
    if LC_ALL=C grep -Eaq -- "$_pat" "$_f" 2>/dev/null; then
      SCAN_REASON="denylist:$_pat"; return 1
    fi
  done
  if command -v clamscan >/dev/null 2>&1; then
    if ! clamscan --no-summary --stdout "$_f" >/dev/null 2>&1; then
      SCAN_REASON="clamav"; return 1
    fi
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Validate the diode list once. A pair must be SRC>DST with both distinct and
# both enabled; anything else is refused rather than silently skipped, so a typo
# fails loudly instead of leaving a diode the operator thinks exists.
# -----------------------------------------------------------------------------
validate_pair() {
  case "$1" in *'>'*) : ;; *) die "Malformed diode '$1' — expected SRC>DST." ;; esac
  _s="${1%%>*}"; _d="${1##*>}"
  [ -n "$_s" ] && [ -n "$_d" ] || die "Malformed diode '$1' — expected SRC>DST."
  [ "$_s" != "$_d" ] || die "Diode '$1' has the same source and destination."
  [ -n "$(env_index "$_s")" ] || die "Diode '$1': unknown source environment '$_s'."
  [ -n "$(env_index "$_d")" ] || die "Diode '$1': unknown destination environment '$_d'."
}
for p in $DIODES; do validate_pair "$p"; done
if [ -n "$ONLY_PAIR" ]; then
  # A --pair the operator names must be one that is actually configured, or the
  # request is refused: the diode set is the authorization list (§3.18.2), and a
  # CLI flag must not be able to invent a channel that config never permitted.
  _found=0; for p in $DIODES; do [ "$p" = "$ONLY_PAIR" ] && _found=1; done
  [ "$_found" = "1" ] || die "Pair '$ONLY_PAIR' is not in DIODES — refusing (an unlisted diode is not authorized)."
fi

# process_pair SRC DST — move every pending file of one diode, mediated + logged.
DELIVERED=0; REFUSED=0; PENDING=0
process_pair() {
  src="$1"; dst="$2"
  if ! env_enabled "$src"; then warn "[$src>$dst] source '$src' is disabled — skipping."; return 0; fi
  if ! env_enabled "$dst"; then warn "[$src>$dst] destination '$dst' is disabled — skipping."; return 0; fi
  outbox="$(diode_base "$src")/$DIODE_OUTBOX/$dst"
  inbox="$(diode_base "$dst")/$DIODE_INBOX/$src"

  # List the source outbox for this destination. -1 one-per-line; failure (dir
  # absent) is fine and just means "nothing queued".
  if ! ga_exec "$src" "ls -1 -- '$outbox' 2>/dev/null || true"; then
    warn "[$src>$dst] source guest agent not ready — re-run once '$src' has booted."
    return 0
  fi
  names="$GA_OUT"
  [ -n "$names" ] || { log "[$src>$dst] nothing queued."; return 0; }

  # The name list is read on fd 3, NOT stdin: the §3.18.4 acceptance prompt below
  # reads the operator's y/N from stdin (the terminal), so the loop must not hold
  # stdin open on the file. A temp file (not `printf | while`) also keeps the loop
  # in THIS shell, so the counters below actually survive the run.
  namefile="$(mktemp)"; printf '%s\n' "$names" > "$namefile"
  while IFS= read -r name <&3; do
    [ -n "$name" ] || continue
    PENDING=$((PENDING+1))
    if ! safe_name "$name"; then
      warn "[$src>$dst] refusing unsafe filename: $name"
      audit_event diode-transfer "src=$src" "dst=$dst" "file=$name" \
        decision=refused reason=unsafe-name
      REFUSED=$((REFUSED+1)); continue
    fi
    srcpath="$outbox/$name"
    tmp="$(mktemp)"

    # 1) Pull the bytes to the host (§3.18.1 file only), enforcing the size cap.
    rc=0; gf_read "$src" "$srcpath" "$tmp" "$DIODE_MAX_BYTES" || rc=$?
    if [ "$rc" = "2" ]; then
      warn "[$src>$dst] $name exceeds DIODE_MAX_BYTES ($DIODE_MAX_BYTES) — refused."
      audit_event diode-transfer "src=$src" "dst=$dst" "file=$name" \
        decision=refused reason=too-big
      REFUSED=$((REFUSED+1)); rm -f "$tmp"; continue
    elif [ "$rc" != "0" ]; then
      warn "[$src>$dst] could not read $name from the source guest — skipping."
      rm -f "$tmp"; continue
    fi
    bytes="$(_filesize "$tmp")"
    hash="$(sha256sum "$tmp" | awk '{print $1}')"

    # 2) §3.18.6 vetting on the host copy, before it can reach the destination.
    if ! scan_file "$tmp"; then
      warn "[$src>$dst] $name rejected by content scan ($SCAN_REASON) — refused."
      audit_event diode-transfer "src=$src" "dst=$dst" "file=$name" \
        "sha256=$hash" "bytes=$bytes" decision=refused "reason=$SCAN_REASON"
      REFUSED=$((REFUSED+1)); rm -f "$tmp"; continue
    fi

    # 3) list mode stops here: report, transfer nothing.
    if [ "$MODE" = "list" ]; then
      printf '  %-16s %10s bytes  %s  %s\n' "$src>$dst" "$bytes" "${hash:0:12}" "$name" >&2
      rm -f "$tmp"; continue
    fi

    # 4) §3.18.4 acceptance on the socle (a support surface outside both domains).
    if [ "$ASSUME_YES" != "1" ]; then
      printf '\nDiode %s\n  file : %s\n  size : %s bytes\n  sha256: %s\nDeliver this file to %s? [y/N] ' \
        "$src>$dst" "$name" "$bytes" "$hash" "$dst" >&2
      read -r ans || ans=""
      case "$ans" in
        y|Y|yes|YES) : ;;
        *)
          warn "[$src>$dst] $name refused by operator."
          audit_event diode-transfer "src=$src" "dst=$dst" "file=$name" \
            "sha256=$hash" "bytes=$bytes" decision=refused reason=operator
          REFUSED=$((REFUSED+1)); rm -f "$tmp"; continue ;;
      esac
    fi

    # 5) Deliver. Ensure the destination inbox exists, avoid clobbering an
    #    existing file (a diode delivers, it does not overwrite), then write.
    ga_exec "$dst" "mkdir -p -- '$inbox'" || {
      warn "[$src>$dst] destination guest agent not ready — $name left queued."
      rm -f "$tmp"; continue
    }
    dstname="$name"
    if ga_exec "$dst" "test -e '$inbox/$name' && echo EXISTS || true" && [ "$GA_OUT" = "EXISTS" ]; then
      dstname="$(date -u +%Y%m%dT%H%M%SZ)-$name"
    fi
    if ! gf_write "$dst" "$inbox/$dstname" "$tmp"; then
      warn "[$src>$dst] failed to write $name into '$dst' — left queued, NOT logged as delivered."
      rm -f "$tmp"; continue
    fi

    # 6) Remove the source copy so the outbox reflects "sent", and log success.
    ga_exec "$src" "rm -f -- '$srcpath'" || warn "[$src>$dst] delivered $name but could not clear the source copy."
    audit_event diode-transfer "src=$src" "dst=$dst" "file=$dstname" \
      "sha256=$hash" "bytes=$bytes" decision=delivered
    ok "[$src>$dst] delivered $name ($bytes bytes) -> $dst:$inbox/$dstname"
    DELIVERED=$((DELIVERED+1))
  done 3< "$namefile"
  rm -f "$namefile"
}

step "PA-114 §3.18 file diodes"
for p in $DIODES; do
  [ -z "$ONLY_PAIR" ] || [ "$p" = "$ONLY_PAIR" ] || continue
  s="${p%%>*}"; d="${p##*>}"
  log "Diode $s -> $d"
  process_pair "$s" "$d"
done

if [ "$MODE" = "list" ]; then
  log "$PENDING file(s) pending across the configured diodes (nothing was transferred)."
else
  log "Diode run complete: $DELIVERED delivered, $REFUSED refused, $PENDING seen."
  log "Full record in the audit log:  audit_tail | grep diode-transfer"
fi
