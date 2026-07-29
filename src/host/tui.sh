#!/bin/sh
# =============================================================================
# host/tui.sh — full-screen operator console for the INSTALLED appliance
# -----------------------------------------------------------------------------
# The person standing in front of the laptop is NOT assumed to be an expert.
# This is the one screen they get: a status dashboard that says in plain
# language whether the environments are still fenced off, a guided first-run
# sequence that walks the setup steps in the right order, and an operations
# menu for the day-two tasks (passwords, VPN, scrubbing, updates, USB).
#
# RENDERING: every screen is written ONCE, against a small dispatch layer
# (ui_msg / ui_yesno / ui_menu / ui_input / ui_password / ui_view). When the
# `dialog` binary is present AND we have a usable terminal, the layer renders
# with dialog; otherwise the SAME screen falls back to a plain numbered text
# menu on stderr/stdout. The fallback must never crash: no dialog, a dumb
# terminal, or stdin that is a pipe all still work. Force the fallback with
# TUI_NO_DIALOG=1 (this is what the test suite does).
#
# CONTRACTS honoured here:
#   A: /run/appliance/isolation.status — one TAB-separated line
#      "STATE EPOCH DETAIL", STATE in OK|FAIL|UNKNOWN. A missing or unparsable
#      file means UNKNOWN. Reading it must NEVER crash this console: a console
#      that dies exactly when the machine is in a weird state is worse than no
#      console. (APPLIANCE_STATUS_FILE overrides the path, used by the tests.)
#   B: major operator actions are recorded with audit_event from
#      lib/common.sh. audit_event never aborts, so auditing can never wedge
#      the console either.
#
# Runs as root on the appliance (tty2, Ctrl+Alt+F2), from /opt/appliance.
# Launched by ./setup-machine.sh with no arguments.
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root

# The dashboard, the VM list and the audit view are all useful BEFORE
# config.env exists (a box whose first-boot provisioning half-failed is exactly
# where the operator needs this console). So a missing config is a warning,
# not a death sentence — only the actions that genuinely need the environment
# model check for it again when they run.
if [ -f "$CONFIG_ENV" ]; then
  load_config
else
  warn "config.env not found — dashboard-only mode (first-boot provisioning may not have finished)."
fi

# libvirt's system URI, same as every other script here.
export LIBVIRT_DEFAULT_URI=qemu:///system

# CONTRACT A (reader side). Overridable for the tests only.
STATUS_FILE="${APPLIANCE_STATUS_FILE:-/run/appliance/isolation.status}"

# --- UI dispatch layer -------------------------------------------------------
# One probe, up front: dialog is used only when it can actually work. /dev/tty
# must be there because dialog draws on stdout and takes answers on stderr —
# we redirect the UI to /dev/tty and capture the answer, so a piped stdin
# (tests, automation) must never reach the dialog path.
USE_DIALOG=0
if [ "${TUI_NO_DIALOG:-0}" != "1" ] && command -v dialog >/dev/null 2>&1 \
   && [ -n "${TERM:-}" ] && [ "${TERM:-dumb}" != "dumb" ] \
   && [ -r /dev/tty ] && [ -w /dev/tty ]; then
  USE_DIALOG=1
fi

# dialog idiom used below: `2>&1 >/dev/tty </dev/tty` — the answer (dialog's
# stderr) lands in the command substitution while the curses UI (dialog's
# stdout) and the keypresses go to the real terminal. dialog's exit code:
# 0 = answered, 1 = Cancel/Esc, 255 = the dialog itself failed (no tty,
# TERM broke) — and 255 is when we silently drop to the text rendering of the
# SAME screen, so a broken terminal degrades instead of crashing.

# ui_msg TITLE TEXT — show information, wait for an acknowledgement.
ui_msg() {
  if [ "$USE_DIALOG" = "1" ]; then
    _rc=0
    dialog --title "$1" --msgbox "$2" 0 0 >/dev/tty </dev/tty 2>&1 || _rc=$?
    if [ "$_rc" -eq 0 ]; then return 0; fi
  fi
  # Text fallback: everything on stderr so callers capturing a function's
  # stdout (ui_menu/ui_input answers) are never polluted by chrome.
  printf '\n=== %s ===\n%s\n\n[Press Enter to continue] ' "$1" "$2" >&2
  read -r _ack || true
  return 0
}

# ui_view TITLE FILE — page a file (audit log); the file path, not its content,
# is the argument so dialog --textbox can use it directly.
ui_view() {
  if [ "$USE_DIALOG" = "1" ]; then
    _rc=0
    dialog --title "$1" --textbox "$2" 0 0 >/dev/tty </dev/tty 2>&1 || _rc=$?
    if [ "$_rc" -eq 0 ]; then return 0; fi
  fi
  printf '\n=== %s ===\n' "$1" >&2
  cat "$2" >&2
  printf '\n[Press Enter to continue] ' >&2
  read -r _ack || true
  return 0
}

# ui_yesno TITLE TEXT — 0 = yes, 1 = no. Text default is NO: every yes in this
# console gates something irreversible-ish, so a blank/mangled answer must be
# the safe one.
ui_yesno() {
  if [ "$USE_DIALOG" = "1" ]; then
    _rc=0
    dialog --title "$1" --yesno "$2" 0 0 >/dev/tty </dev/tty 2>&1 || _rc=$?
    case "$_rc" in
      0) return 0 ;;
      1) return 1 ;;
    esac
  fi
  printf '\n%s\n%s [y/N]: ' "$1" "$2" >&2
  read -r _a || _a=""
  case "$_a" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

# ui_menu TITLE PROMPT TAG LABEL [TAG LABEL ...] — print the chosen TAG on
# stdout. Menus and prompts go to stderr in text mode so the capture stays
# clean. Every menu in this script carries a `q` tag, which is what Cancel/Esc
# and end-of-input both map to: a console that spins forever reprinting a menu
# on EOF (stdin from /dev/null or an exhausted pipe) would hang setup-machine.sh.
ui_menu() {
  _t="$1"; _p="$2"; shift 2
  if [ "$USE_DIALOG" = "1" ]; then
    _rc=0
    _a="$(dialog --title "$_t" --menu "$_p" 0 0 0 "$@" 2>&1 >/dev/tty </dev/tty)" || _rc=$?
    case "$_rc" in
      0) printf '%s' "$_a"; return 0 ;;
      1) printf 'q'; return 0 ;;
    esac
  fi
  _tags=""
  printf '\n=== %s ===\n%s\n\n' "$_t" "$_p" >&2
  while [ $# -ge 2 ]; do
    printf '  %s) %s\n' "$1" "$2" >&2
    _tags="$_tags $1"
    shift 2
  done
  while :; do
    printf '\nChoice: ' >&2
    if ! read -r _c; then
      printf '\n' >&2
      printf 'q'
      return 0
    fi
    # Match against the exact tag list — a substring/regex match would let a
    # mistyped choice silently select the wrong action on a security box. The
    # typed choice goes INTO a case pattern, so reject anything with glob
    # metacharacters first (a literal '*' would wildcard its way to a match).
    case "$_c" in
      ''|*[!a-zA-Z0-9]*) printf 'Invalid choice — pick one of:%s\n' "$_tags" >&2; continue ;;
    esac
    case " $_tags " in
      *" $_c "*) printf '%s' "$_c"; return 0 ;;
    esac
    printf 'Invalid choice — pick one of:%s\n' "$_tags" >&2
  done
}

# ui_input TITLE PROMPT — print the answer (possibly empty) on stdout.
ui_input() {
  if [ "$USE_DIALOG" = "1" ]; then
    _rc=0
    _a="$(dialog --title "$1" --inputbox "$2" 0 0 2>&1 >/dev/tty </dev/tty)" || _rc=$?
    case "$_rc" in
      0) printf '%s' "$_a"; return 0 ;;
      1) printf ''; return 0 ;;
    esac
  fi
  printf '\n%s\n%s ' "$1" "$2" >&2
  read -r _a || _a=""
  printf '%s' "$_a"
}

# ui_password TITLE PROMPT — like ui_input but without echo where the terminal
# allows it. stty needs a real tty; on a pipe it fails and we simply read
# plainly (tests), guarded so set -e never sees it.
ui_password() {
  if [ "$USE_DIALOG" = "1" ]; then
    _rc=0
    _a="$(dialog --title "$1" --passwordbox "$2" 0 0 2>&1 >/dev/tty </dev/tty)" || _rc=$?
    case "$_rc" in
      0) printf '%s' "$_a"; return 0 ;;
      1) printf ''; return 0 ;;
    esac
  fi
  printf '\n%s\n%s ' "$1" "$2" >&2
  stty -echo 2>/dev/null || true
  read -r _a || _a=""
  stty echo 2>/dev/null || true
  printf '\n' >&2
  printf '%s' "$_a"
}

# --- CONTRACT A reader -------------------------------------------------------
# Never dies: any parse problem downgrades to UNKNOWN with the reason as the
# detail. ISO_STATE / ISO_EPOCH / ISO_DETAIL are set for the caller.
read_isolation() {
  ISO_STATE="UNKNOWN"
  ISO_EPOCH=""
  ISO_DETAIL="no status file — the isolation check has not run yet on this boot"
  if [ -r "$STATUS_FILE" ]; then
    _line="$(head -n1 "$STATUS_FILE" 2>/dev/null || true)"
    _st="$(printf '%s' "$_line" | cut -f1 2>/dev/null || true)"
    case "$_st" in
      OK|FAIL|UNKNOWN)
        ISO_STATE="$_st"
        ISO_EPOCH="$(printf '%s' "$_line" | cut -f2 2>/dev/null || true)"
        ISO_DETAIL="$(printf '%s' "$_line" | cut -f3- 2>/dev/null || true)"
        ;;
      *)
        ISO_DETAIL="status file is unreadable or garbage — treating the verdict as UNKNOWN"
        ;;
    esac
  fi
}

# --- action runner -----------------------------------------------------------
# run_action LABEL CMD [ARGS...] — the single path every real action takes.
# It says what it is about to run BEFORE running it, captures the output,
# shows the tail with a plain OK/FAILED verdict, waits for an acknowledgement,
# and audits the outcome. Failures are shown, never hidden — the operator
# standing at the machine is the incident response of last resort.
run_action() {
  _label="$1"; shift
  ui_msg "About to run" "$(printf '%s' "$*")"
  _out="$(mktemp /tmp/appliance-tui.XXXXXX)"
  _rc=0
  "$@" >"$_out" 2>&1 || _rc=$?
  if [ "$_rc" -eq 0 ]; then _res="OK"; else _res="FAILED (exit $_rc)"; fi
  _tail="$(tail -n 15 "$_out" 2>/dev/null || true)"
  rm -f "$_out"
  ui_msg "$_label — $_res" "${_tail:-(no output)}"
  audit_event tui "action=$_label" "result=$_res"
  return 0
}

# --- screens -----------------------------------------------------------------

# Status dashboard: the answer to "is this machine still safe to use?", in
# order of importance — the isolation verdict first, then what the VMs are
# doing, whether there is any uplink at all, and what the audit trail saw last.
screen_dashboard() {
  read_isolation
  case "$ISO_STATE" in
    OK)   _plain="OK — the firewall between the environments is verified in place." ;;
    FAIL) _plain="FAIL — THE ENVIRONMENTS ARE NOT FENCED OFF RIGHT NOW. Do not mix trust levels on this machine; re-run environments/isolate.sh." ;;
    *)    _plain="UNKNOWN — nobody can currently vouch for the isolation. Treat the machine as unverified." ;;
  esac
  case "$ISO_EPOCH" in
    ''|*[!0-9]*) _when="never" ;;
    *)           _when="$(( $(date +%s) - ISO_EPOCH )) seconds ago" ;;
  esac

  _dash() {
    printf 'ISOLATION: %s\n' "$_plain"
    printf '  last check: %s\n' "$_when"
    if [ -n "$ISO_DETAIL" ]; then printf '  detail: %s\n' "$ISO_DETAIL"; fi
    printf '\nVIRTUAL MACHINES (virsh list --all):\n'
    if command -v virsh >/dev/null 2>&1; then
      virsh list --all 2>&1 | sed 's/^/  /' || printf '  (virsh failed)\n'
    else
      printf '  virsh not installed on this host\n'
    fi
    _up="$(ip route show default 2>/dev/null | head -n1 || true)"
    printf '\nUPLINK: %s\n' "${_up:-no default route — the VMs have no internet}"
    printf '\nRECENT AUDIT EVENTS (last 10):\n'
    _ev="$(audit_tail 10 2>/dev/null || true)"
    if [ -n "$_ev" ]; then printf '%s\n' "$_ev" | sed 's/^/  /'; else printf '  (none yet)\n'; fi
  }
  ui_msg "Appliance status" "$(_dash)"

  if ui_yesno "Isolation check" "Re-run the isolation check now? (host/isolation-watch.sh --once)"; then
    run_action "isolation-check" "$HERE/isolation-watch.sh" --once
  fi
}

# Guided first setup: the same order setup-machine.sh has always documented —
# uplink first (the guests need internet on their first boot), portal sign-in
# next, the long VM download, and the isolation fence + proof last. Every step
# is individually skippable: forcing a step the box doesn't need (wired
# uplink, no portal) would push operators toward answering blindly.
screen_guided() {
  ui_msg "Guided first setup" "This walks the first-run steps in order:\n\n  1. Wi-Fi uplink (skip on a wired connection)\n  2. Captive-portal sign-in (Super+p on the desktop)\n  3. Create the VMs (downloads gigabytes — long)\n  4. Isolate the environments and verify\n\nEach step asks before it runs; answer n to skip it."

  if ui_yesno "Guided setup 1/4: Wi-Fi uplink" "Set up the Wi-Fi uplink now (host/wifi.sh)? Answer n if this machine is on a wired connection."; then
    run_action "wifi" "$HERE/wifi.sh"
  else
    audit_event tui action=guided-wifi result=skipped
  fi

  ui_msg "Guided setup 2/4: captive portal" "If this network needs a web sign-in (hotel, enterprise, Entra/OAuth):\nswitch to the desktop with Ctrl+Alt+F1 and press Super+p, sign in once, then come back here with Ctrl+Alt+F2.\n\nNothing runs on this screen — the sign-in happens in the desktop browser. NAT puts every VM online once the host itself is online."
  if ui_yesno "Guided setup 2/4: captive portal" "Have you completed the portal sign-in — or does this network not need one?"; then
    audit_event tui action=guided-portal result=ok
  else
    warn "The VMs get no internet until Wi-Fi AND any portal sign-in are done."
    audit_event tui action=guided-portal result=skipped
  fi

  if ui_yesno "Guided setup 3/4: create the VMs" "Create the virtual machines now (environments/create.sh)?\n\nWARNING: this downloads GIGABYTES of base images and can take a very long time on a slow link. The uplink and any portal sign-in must be done first."; then
    run_action "create-vms" "$APP_ROOT/environments/create.sh"
  else
    audit_event tui action=guided-create result=skipped
  fi

  if ui_yesno "Guided setup 4/4: isolate + verify" "Build the firewall between the environments and verify it now (environments/isolate.sh)? Without this step the environments can talk to each other."; then
    run_action "isolate" "$APP_ROOT/environments/isolate.sh"
  else
    audit_event tui action=guided-isolate result=skipped
  fi

  ui_msg "Guided setup" "Guided setup complete. Check the status dashboard (main menu, entry 1) for the isolation verdict."
}

# --- operations ---------------------------------------------------------------

op_password() {
  if [ ! -f "$CONFIG_ENV" ]; then
    ui_msg "Change a VM password" "No config.env — the environment model does not exist yet."
    return 0
  fi
  _tags="$(for_each_enabled_env | awk '{print $1}' 2>/dev/null || true)"
  if [ -z "$_tags" ]; then
    ui_msg "Change a VM password" "No enabled environments found in config.env."
    return 0
  fi
  _env="$(ui_input "Change a VM password" "Which environment? One of: $(printf '%s' "$_tags" | tr '\n' ' ')")"
  if [ -z "$_env" ]; then return 0; fi
  _pw1="$(ui_password "Change a VM password" "New password for '$_env':")"
  _pw2="$(ui_password "Change a VM password" "Repeat the new password:")"
  if [ -z "$_pw1" ]; then
    ui_msg "Change a VM password" "Empty password — refused. Nothing was changed."
    return 0
  fi
  if [ "$_pw1" != "$_pw2" ]; then
    ui_msg "Change a VM password" "The two entries did not match. Nothing was changed."
    return 0
  fi
  # The password travels as an argument because the underlying script accepts
  # it that way (it would otherwise prompt on a terminal dialog has taken
  # over). It is visible in the process list for the seconds the call takes —
  # noted in the script's own header; the alternative is an unreadable prompt.
  run_action "password-$_env" "$APP_ROOT/environments/set-guest-password.sh" "$_env" "$_pw1"
}

op_vpn() {
  if ui_yesno "Per-env VPN" "Bring up the per-environment WireGuard tunnels now (environments/vpn.sh)?\n\nOnly environments with <env>_VPN=1 in config.env are touched. The tunnel is FAIL-CLOSED: if it is down, that environment has NO internet rather than leaking around it."; then
    run_action "vpn" "$APP_ROOT/environments/vpn.sh"
  fi
}

op_scrub() {
  ui_msg "Scrub secrets" "This blanks every secret in config.env (guest password, Wi-Fi PSK, LUKS passphrase, WireGuard private keys) and removes the generated-secrets notes and the cloud-init seed ISOs.\n\nThis is NOT UNDOABLE from this machine: the values are gone. Only do this once the VMs are created, isolated, and you have recorded anything you still need elsewhere."
  if ui_yesno "Scrub secrets" "Really scrub all secrets from this appliance now?"; then
    run_action "scrub-secrets" "$APP_ROOT/environments/scrub-secrets.sh"
  fi
}

op_secureboot() {
  if ui_yesno "Secure Boot / TPM" "Set up Secure Boot and TPM sealing now (host/secure-boot.sh)?\n\nWARNING: a mistake here can make the machine refuse to boot. Only run this on the final hardware, once everything else works."; then
    run_action "secure-boot" "$HERE/secure-boot.sh"
  fi
}

op_usb() {
  ui_msg "Allow a USB device" "The appliance blocks all USB except keyboards/mice by default. The next step lists the connected devices; you then pick ONE device id to permanently allow past usbguard.\n\nAllowing a data device weakens the peripheral fence — allow only what a specific environment genuinely needs."
  run_action "usb-list" "$HERE/usb-allow.sh" list
  _id="$(ui_input "Allow a USB device" "Device id to allow (empty to cancel):")"
  if [ -n "$_id" ]; then
    run_action "usb-allow" "$HERE/usb-allow.sh" allow "$_id"
  fi
}

op_update_check() {
  if ui_yesno "Check for updates" "Check what appliance update is available (host/update.sh --check)?\n\nThis only downloads the release metadata and reports — it changes nothing."; then
    run_action "update-check" "$HERE/update.sh" --check
  fi
}

op_update_apply() {
  ui_msg "Apply an appliance update" "This downloads the signed release, verifies it, and REPLACES the appliance code in /opt/appliance.\n\nYour config.env, the VMs and their data are kept, and the previous tree is kept as a backup (rollback is the next menu entry). But this is remote code becoming root on this machine — the signature is the only thing standing between you and a hostile mirror, which is why updates are REFUSED when no release key is pinned in config.env (UPDATE_GPG_FPR)."
  if ui_yesno "Apply an appliance update" "Really fetch, verify and apply the update now?"; then
    run_action "update-apply" "$HERE/update.sh"
  fi
}

op_update_rollback() {
  if ui_yesno "Roll back the last update" "Restore the previous appliance tree (host/update.sh --rollback)?\n\nThe current tree is replaced by the most recent backup taken by a previous update."; then
    run_action "update-rollback" "$HERE/update.sh" --rollback
  fi
}

op_audit() {
  _f="$(mktemp /tmp/appliance-tui-audit.XXXXXX)"
  audit_tail 50 > "$_f" 2>/dev/null || true
  ui_view "Audit log — last 50 events" "$_f"
  rm -f "$_f"
}

screen_ops() {
  while :; do
    _c="$(ui_menu "Operations" "Day-two tasks. Each one confirms before it acts." \
      1 "Change a VM password" \
      2 "Per-env VPN setup" \
      3 "Scrub secrets (irreversible)" \
      4 "Secure Boot / TPM" \
      5 "Allow a USB device" \
      6 "Check for appliance updates" \
      7 "Apply appliance update" \
      8 "Roll back the last update" \
      9 "View the audit log" \
      10 "View / refresh isolation status" \
      q "Back to the main menu")"
    case "$_c" in
      1)  op_password ;;
      2)  op_vpn ;;
      3)  op_scrub ;;
      4)  op_secureboot ;;
      5)  op_usb ;;
      6)  op_update_check ;;
      7)  op_update_apply ;;
      8)  op_update_rollback ;;
      9)  op_audit ;;
      10) screen_dashboard ;;
      q)  return 0 ;;
    esac
  done
}

# --- main loop ----------------------------------------------------------------
audit_event tui action=launch result=ok
while :; do
  _c="$(ui_menu "Appliance operator console" "What do you want to do?" \
    1 "Status dashboard" \
    2 "Guided first setup" \
    3 "Operations" \
    q "Exit to a root shell")"
  case "$_c" in
    1) screen_dashboard ;;
    2) screen_guided ;;
    3) screen_ops ;;
    q)
      audit_event tui action=exit result=ok
      printf '\nLeaving the console. You are at a ROOT shell — type carefully.\n' >&2
      printf 'Reopen the console any time with:  ./setup-machine.sh\n\n' >&2
      exit 0
      ;;
  esac
done
