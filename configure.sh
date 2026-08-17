#!/bin/sh
# =============================================================================
# configure.sh — step 1 of 3: write the appliance's config.env
# -----------------------------------------------------------------------------
# The FIRST of three endpoints, in order:
#   1. ./configure.sh   (this script) — answer questions, write config.env
#   2. ./flash.sh                      — build the image and flash a USB stick
#   3. ./setup.sh                      — on the appliance: create + isolate VMs
#
# A zero-dependency, fully interactive walkthrough for a FIRST-TIME user (no
# prior knowledge of the appliance assumed). It asks plain-language questions
# and writes the answers to ./config.env (mode 0600) — and NOTHING else. It
# never builds or flashes: that is ./flash.sh's job (strict separation, so each
# endpoint does exactly one thing).
#
#   ./configure.sh              # interactive wizard
#   ./configure.sh --defaults   # write config.env from built-in defaults,
#                               # no questions (CI/tests). An existing
#                               # config.env is backed up, never clobbered.
#   ./configure.sh -h|--help    # usage
#
# Runs on the BUILD host (macOS bash 3.2 AND Linux), so: strictly POSIX sh.
# Every prompt reads stdin with `read -r` and treats an empty answer (or EOF,
# e.g. a closed pipe) as "keep the default", so piped answers work.
#
# SAFETY CONTRACT:
#   * config.env is written ATOMICALLY (temp file + mv) and always ends 0600 —
#     it holds secrets (passwords, Wi-Fi PSK, LUKS passphrase).
#   * An existing config.env is NEVER overwritten without consent: the wizard
#     asks to back it up to config.env.bak-YYYYMMDD-HHMMSS first; refusing
#     leaves the old file byte-for-byte untouched.
#   * Ctrl+C anywhere aborts with a friendly message and removes the temp file;
#     because the write happens once at the very end, an interrupt can never
#     leave a half-written config.env.
#   * SKIP_PREFLIGHT=1 skips the docker/disk host checks (test hook; the real
#     build re-checks docker itself anyway).
# =============================================================================
set -eu

# This script lives at the REPO ROOT, one level ABOVE src/ where every other
# script lives. src/lib.sh derives APP_ROOT/CONFIG_ENV from the calling
# script's location assuming the caller is inside src/ — so after sourcing we
# re-point both at the real root. (log/ok/warn/die are what we actually want
# from the library.)
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/src/lib.sh"
APP_ROOT="$HERE"
CONFIG_ENV="$HERE/config.env"

# The three environments are FIXED and ordered: position in $ENVS fixes each
# env's workspace number, subnet and bridge (see src/lib.sh), so the wizard
# only ever toggles <env>_ENABLED — it never reorders or renames this list.
ENVS="office development administration"

# --- input helpers -------------------------------------------------------------
# Every answer passes through clean_val before it is eval'd into a variable and
# eventually written inside double quotes in config.env: '"', '\', '$' and '`'
# would otherwise break the file's syntax (or worse, execute when config.env is
# later SOURCED by every appliance script). A password containing one of those
# four characters is mangled by this — acceptable, and far safer than sourcing
# unsanitised input.
clean_val() { printf '%s' "$1" | tr -d '"`$\\'; }

# ask VAR PROMPT DEFAULT — one free-form question. Empty answer (or EOF on a
# closed stdin) keeps DEFAULT. The default is shown in the prompt.
ask() {
  _a_var="$1"; _a_prompt="$2"; _a_def="$3"
  printf '%s [%s]: ' "$_a_prompt" "$_a_def"
  IFS= read -r _a_ans || _a_ans=""
  [ -n "$_a_ans" ] || _a_ans="$_a_def"
  _a_ans="$(clean_val "$_a_ans")"
  eval "$_a_var=\$_a_ans"
}

# ask_required VAR PROMPT — like ask, but a value is MANDATORY when the
# variable has none: secrets are never auto-generated, so a password question
# must be answered. If the variable already holds a value (an existing
# config.env was loaded), blank keeps it and the prompt masks it. Three
# strikes and out, so a piped blank stream fails instead of looping forever;
# a closed stdin with no current value dies immediately.
ask_required() {
  _r_var="$1"; _r_prompt="$2"
  eval "_r_cur=\"\${$_r_var:-}\""
  _r_n=0
  while :; do
    if [ -n "$_r_cur" ]; then
      printf '%s [********]: ' "$_r_prompt"
      IFS= read -r _r_ans || _r_ans=""
      [ -z "$_r_ans" ] && return 0
    else
      printf '%s (required): ' "$_r_prompt"
      IFS= read -r _r_ans || die "$_r_prompt: a value is required (input closed)."
    fi
    _r_ans="$(clean_val "$_r_ans")"
    [ -n "$_r_ans" ] && { eval "$_r_var=\$_r_ans"; return 0; }
    _r_n=$((_r_n+1)); [ "$_r_n" -ge 3 ] && die "$_r_prompt: no value given after 3 attempts."
    warn "A value is required — no default, no auto-generation."
  done
}

# ask_yn VAR PROMPT DEFAULT(0|1) — yes/no question. Lenient by design: the
# audience is non-expert, and with piped input a retry loop would silently
# consume the NEXT answer. So an unparseable answer warns and keeps the default.
ask_yn() {
  _y_word="n"; [ "$3" = "1" ] && _y_word="y"
  printf '%s [%s]: ' "$2" "$_y_word"
  IFS= read -r _y_ans || _y_ans=""
  case "$_y_ans" in
    "")        eval "$1=$3" ;;
    [yY1]*)    eval "$1=1" ;;
    [nN0]*)    eval "$1=0" ;;
    *) warn "Please answer y or n — keeping the default ($_y_word)."
       eval "$1=$3" ;;
  esac
}

# ask_choice VAR PROMPT DEFAULT opt... — constrained choice. An out-of-list
# answer warns and keeps the default (same piped-input rationale as ask_yn).
ask_choice() {
  _c_var="$1"; _c_prompt="$2"; _c_def="$3"; shift 3
  printf '%s [%s]: ' "$_c_prompt" "$_c_def"
  IFS= read -r _c_ans || _c_ans=""
  [ -n "$_c_ans" ] || _c_ans="$_c_def"
  _c_ok=0
  for _c_opt in "$@"; do [ "$_c_ans" = "$_c_opt" ] && _c_ok=1; done
  if [ "$_c_ok" = "0" ]; then
    warn "Unknown choice — keeping the default ($_c_def)."
    _c_ans="$_c_def"
  fi
  eval "$_c_var=\$_c_ans"
}

# mask VALUE — never echo a real secret back in the summary screen; only the
# empty string is safe to show as-is.
mask() { case "$1" in "") printf '%s' "(empty)" ;; *) printf '********' ;; esac; }

# --- Ctrl+C / kill handling -----------------------------------------------------
# The write to config.env happens exactly once, at the very end, atomically —
# so an interrupt anywhere in the question flow has nothing written to clean
# up beyond the (not yet created) temp file. 130 = 128+SIGINT, the convention.
TMP_FILE=""
cleanup() { [ -n "$TMP_FILE" ] && rm -f "$TMP_FILE" 2>/dev/null; return 0; }
on_int() {
  printf '\n' >&2
  warn "Interrupted (Ctrl+C) — config.env was NOT written. Re-run ./configure.sh any time."
  exit 130
}
trap on_int INT TERM
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./configure.sh [--defaults] [-h|--help]

Step 1 of 3. Interactive first-run wizard: asks about environments, credentials,
Wi-Fi, security toggles, base-image pinning and build options, then writes
./config.env (0600). It does not build or flash — run ./flash.sh next.

  --defaults   write config.env from the built-in defaults without asking
               (CI/tests; an existing config.env is backed up first)
  -h, --help   this help
EOF
}

# --- preflight ------------------------------------------------------------------
preflight() {
  [ "${SKIP_PREFLIGHT:-0}" = "1" ] && return 0
  log "Checking the build host ..."
  # Docker is the ONE hard requirement: the appliance rootfs is assembled inside
  # a privileged Alpine container (macOS has neither loop devices nor the Linux
  # tooling to build one natively). Everything below it is advisory.
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker is not installed — src/build.sh cannot run without it."
    ask_yn PF_Q "Continue anyway (write config.env only, build later)?" 0
    [ "$PF_Q" = "1" ] || die "Install Docker (Docker Desktop on macOS), then re-run ./configure.sh."
  elif ! docker info >/dev/null 2>&1; then
    warn "the Docker daemon is not reachable — is Docker Desktop started?"
    ask_yn PF_Q "Continue anyway (write config.env only, build later)?" 0
    [ "$PF_Q" = "1" ] || die "Start the Docker daemon, then re-run ./configure.sh."
  else
    ok "docker is installed and running."
  fi
  # curl/wget: the build itself downloads inside the container, but fetching
  # vendor checksums for the pinning step below is much easier with one of
  # these on the host. Advisory only.
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "neither curl nor wget found — you will want one to fetch vendor checksums for image pinning."
    ask_yn PF_Q "Continue anyway?" 1
    [ "$PF_Q" = "1" ] || die "Install curl or wget, then re-run ./configure.sh."
  fi
  # Disk: IMG_SIZE qcow2 + the raw intermediate + Docker layers. 20 GB is a
  # comfortable floor, not a hard limit — so a low disk warns, not aborts.
  # awk 'END{print $4}': long device names (macOS) wrap df's output onto two
  # lines; the LAST line always carries the fields, and $4 is available KB.
  _free_kb="$(df -k "$HERE" | awk 'END {print $4}')"
  case "$_free_kb" in
    ""|*[!0-9]*) warn "could not determine free disk space — continuing blind." ;;
    *)
      if [ "$_free_kb" -lt 20971520 ]; then
        warn "less than 20 GB free on this disk — the build needs roughly that for the image + Docker layers."
        ask_yn PF_Q "Continue anyway?" 1
        [ "$PF_Q" = "1" ] || die "Free some disk space, then re-run ./configure.sh."
      else
        ok "disk space looks sufficient."
      fi ;;
  esac
}

# --- defaults -------------------------------------------------------------------
# seed_defaults: interactive mode pre-fills every answer from the EXISTING
# config.env (so each prompt shows the current value as its default), then
# falls back to the built-in defaults (mirroring config.env.example).
# --defaults mode skips the sourcing on purpose: CI must get the built-ins,
# not whatever happens to be lying in the checkout.
seed_defaults() {
  if [ "${DEFAULTS:-0}" != "1" ] && [ -f "$CONFIG_ENV" ]; then
    log "Found an existing config.env — current values become the defaults."
    # shellcheck disable=SC1090
    . "$CONFIG_ENV" || die "Existing config.env could not be read."
  fi
  : "${SUBNET_BASE:=10.10}"
  : "${office_ENABLED:=1}";           : "${office_OS:=ubuntu}";          : "${office_DE:=gnome}"
  : "${development_ENABLED:=1}";      : "${development_OS:=arch}";       : "${development_DE:=gnome}"
  : "${administration_ENABLED:=1}";   : "${administration_OS:=arch}";    : "${administration_DE:=gnome}"
  : "${office_EGRESS_MODE:=all}";          : "${office_EGRESS_ALLOW:=}"
  : "${development_EGRESS_MODE:=all}";     : "${development_EGRESS_ALLOW:=}"
  : "${administration_EGRESS_MODE:=all}";  : "${administration_EGRESS_ALLOW:=}"
  : "${office_ENCRYPT_DISK:=0}"; : "${development_ENCRYPT_DISK:=0}"; : "${administration_ENCRYPT_DISK:=0}"
  : "${GUEST_USER:=operator}"
  # Passwords start EMPTY: secrets are never auto-generated, so the wizard must
  # ask for them (ask_required). --defaults mode plants the well-known
  # placeholder "changeme" below — fine for CI/tests only.
  : "${GUEST_PASSWORD:=}"
  : "${HOST_ROOT_PASSWORD:=}"
  : "${WIFI_SSID:=}"; : "${WIFI_PSK:=}"; : "${WIFI_COUNTRY:=FR}"
  : "${USBGUARD:=1}"; : "${YUBIKEY_ROUTER:=1}"; : "${TRUST_BAR:=1}"
  : "${ENCRYPT:=0}";  : "${LUKS_PASS:=}"
  : "${UBUNTU_IMG_DATE:=}"; : "${UBUNTU_IMG_SHA256:=}"; : "${UBUNTU_IMG_GPG_FPR:=}"
  : "${ARCH_IMG_DATE:=}";   : "${ARCH_IMG_SHA256:=}";   : "${ARCH_IMG_GPG_FPR:=}"
  : "${DEBIAN_IMG_DATE:=}"; : "${DEBIAN_IMG_SHA256:=}"; : "${DEBIAN_IMG_GPG_FPR:=}"
  : "${IMG_SIZE:=4G}"; : "${ALPINE_BRANCH:=v3.22}"; : "${BAKE_CONFIG:=1}"
}

# --- the questions ----------------------------------------------------------------
ask_environments() {
  log "Step 1/6 — environments (the virtual machines)"
  cat <<'EOF'
  The appliance runs up to three ISOLATED virtual machines, side by side:
    office          - the everyday desktop: web, e-mail, documents.
    development     - the coding / build workstation.
    administration  - the sensitive admin workstation (the crown jewels).
  A disabled environment is simply never created; the others are unaffected
  (positions are fixed, so nothing renumbers).
EOF
  cat <<'EOF'
  Guest OS choices:
    ubuntu - Ubuntu LTS: the ONLY OS Microsoft Intune/Entra enrolment supports.
    arch   - Arch Linux: rolling release, always the newest packages.
    debian - Debian stable: conservative, long-tested packages.
  Desktop choices:
    gnome  - full modern desktop; familiar, but the heaviest on RAM.
    xfce4  - light, classic desktop; fastest on modest hardware.
    kde    - polished, Windows-like desktop; heavy but friendly.
    mate   - light, traditional desktop (old-school style).
    lxqt   - very light desktop; minimal resource use.
    none   - no desktop at all: text console only.
EOF
  # _en/_os/_de are assigned via eval below; pre-set them so shellcheck (and a
  # hypothetical typo in the eval) never meets an unset variable.
  _en=""; _os=""; _de=""
  for _e in $ENVS; do
    eval "_en=\$${_e}_ENABLED"
    ask_yn "${_e}_ENABLED" "Enable the '$_e' environment?" "$_en"
    eval "_en=\$${_e}_ENABLED"
    [ "$_en" = "0" ] && continue
    [ "$_e" = "office" ] && \
      warn "NOTE: office MUST stay Ubuntu — Microsoft Intune/Entra enrolment is Ubuntu-only."
    eval "_os=\$${_e}_OS"
    ask_choice "${_e}_OS" "Guest OS for '$_e' (ubuntu/arch/debian)?" "$_os" ubuntu arch debian
    eval "_os=\$${_e}_OS"
    if [ "$_e" = "office" ] && [ "$_os" != "ubuntu" ]; then
      warn "a non-Ubuntu office VM CANNOT be enrolled in Intune/Entra — keeping your choice anyway."
    fi
    eval "_de=\$${_e}_DE"
    ask_choice "${_e}_DE" "Desktop for '$_e' (gnome/xfce4/kde/mate/lxqt/none)?" "$_de" \
      gnome xfce4 kde mate lxqt none
  done
}

ask_credentials() {
  log "Step 2/6 — credentials"
  echo "  GUEST_USER is the login name inside every VM; GUEST_PASSWORD its password"
  echo "  (used for console/virt-viewer login)."
  ask GUEST_USER "Guest user name?" "$GUEST_USER"
  echo "  GUEST_PASSWORD is the login password inside every VM (console/"
  echo "  virt-viewer). Secrets are never auto-generated: what you type is it."
  ask_required GUEST_PASSWORD "Guest password"
  echo "  HOST_ROOT_PASSWORD is the appliance's own root password (admin on tty2,"
  echo "  Ctrl+Alt+F2). The shipped image keeps root LOCKED; first boot sets this."
  ask_required HOST_ROOT_PASSWORD "Host root password"
}

ask_network() {
  log "Step 3/6 — network (host Wi-Fi uplink)"
  echo "  Wi-Fi for the appliance's OWN internet uplink. Optional: leave the SSID"
  echo "  empty and configure it later on the appliance (src/host.sh wifi); a wired"
  echo "  Ethernet connection needs nothing here."
  ask WIFI_SSID "Wi-Fi network name (SSID), empty = wired/skip?" "$WIFI_SSID"
  if [ -n "$WIFI_SSID" ]; then
    ask WIFI_PSK "Wi-Fi password (PSK)?" "$WIFI_PSK"
    echo "  WIFI_COUNTRY is the regulatory domain (ISO 3166-1 alpha-2) so the radio"
    echo "  uses legal channels/power."
    ask WIFI_COUNTRY "Wi-Fi country code?" "$WIFI_COUNTRY"
  fi
}

ask_security() {
  log "Step 4/6 — security toggles"
  echo "  USB lockdown: default-deny for USB devices; anything plugged in after"
  echo "  first boot stays blocked until you explicitly allow it."
  ask_yn USBGUARD "Enable USBGuard (USB lockdown)?" "$USBGUARD"
  echo "  YubiKey chooser: when you plug in a YubiKey you pick which ONE"
  echo "  environment receives it — it is never shared across environments."
  ask_yn YUBIKEY_ROUTER "Enable YubiKey routing?" "$YUBIKEY_ROUTER"
  echo "  Trust bar: a permanent, colour-coded top bar naming the ACTIVE"
  echo "  environment, so you always know which VM you are typing in (ANSSI)."
  ask_yn TRUST_BAR "Enable the trust bar?" "$TRUST_BAR"
  echo "  Full-disk encryption of the appliance itself (LUKS2 at install time,"
  echo "  passphrase at every boot). EXPERIMENTAL: test on a spare machine first —"
  echo "  a bad encrypted install can be unbootable."
  ask_yn ENCRYPT "Encrypt the appliance disk (EXPERIMENTAL)?" "$ENCRYPT"
  if [ "$ENCRYPT" = "1" ]; then
    ask_required LUKS_PASS "LUKS passphrase"
  fi
  echo "  Outbound (egress) policy per environment: 'all' = full internet via NAT;"
  echo "  'whitelist' = DNS plus ONLY the IP addresses you list."
  _en=""; _eg=""; _ea=""; _ed=""
  for _e in $ENVS; do
    eval "_en=\$${_e}_ENABLED"
    [ "$_en" = "0" ] && continue
    eval "_eg=\$${_e}_EGRESS_MODE"
    ask_choice "${_e}_EGRESS_MODE" "Egress policy for '$_e' (all/whitelist)?" "$_eg" all whitelist
    eval "_eg=\$${_e}_EGRESS_MODE"
    if [ "$_eg" = "whitelist" ]; then
      eval "_ea=\$${_e}_EGRESS_ALLOW"
      ask "${_e}_EGRESS_ALLOW" "Allowed IPs/CIDRs for '$_e' (space-separated)?" "$_ea"
    fi
    echo "  Per-env disk encryption makes that VM's disk a LUKS-encrypted qcow2,"
    echo "  unlocked by a passphrase. EXPERIMENTAL — test before relying on it."
    eval "_ed=\$${_e}_ENCRYPT_DISK"
    ask_yn "${_e}_ENCRYPT_DISK" "Encrypt the '$_e' VM disk (EXPERIMENTAL)?" "$_ed"
  done
}

ask_pinning() {
  log "Step 5/6 — supply-chain pinning (optional)"
  echo "  The build downloads base OS images over plain HTTPS with no signature"
  echo "  check of its own. Pins make the build VERIFY them; left empty, images"
  echo "  download UNVERIFIED (a warning is printed at build time)."
  ask_yn DO_PIN "Configure image pinning now?" 0
  [ "$DO_PIN" = "1" ] || return 0
  # Only ask about OSes an ENABLED env actually uses — pinning an image you
  # never download is busywork that goes stale.
  _used=""
  for _e in $ENVS; do
    eval "_en=\$${_e}_ENABLED"; eval "_os=\$${_e}_OS"
    [ "$_en" = "0" ] && continue
    case " $_used " in *" $_os "*) ;; *) _used="$_used $_os" ;; esac
  done
  for _os in $_used; do
    _OS="$(printf '%s' "$_os" | tr '[:lower:]' '[:upper:]')"
    echo "  ${_OS}: the vendor publishes immutable DATED directories next to the"
    echo "  rolling 'current'/'latest' (e.g. 20260701). Pinning one stops a pinned"
    echo "  hash going stale on the next vendor rebuild. Empty = rolling image."
    eval "_d=\$${_OS}_IMG_DATE"
    ask "${_OS}_IMG_DATE" "${_OS} dated directory (empty = rolling)?" "$_d"
    echo "  ${_OS}: the 64-hex SHA256 from the vendor's signed checksum file."
    echo "  Empty = downloaded WITHOUT an integrity check (warning printed)."
    eval "_s=\$${_OS}_IMG_SHA256"
    ask "${_OS}_IMG_SHA256" "${_OS} image SHA256 (empty = unverified)?" "$_s"
    echo "  ${_OS}: fingerprint of the vendor's image-signing key, obtained out of"
    echo "  band; the image's signature must match EXACTLY this key. Empty = off."
    eval "_f=\$${_OS}_IMG_GPG_FPR"
    ask "${_OS}_IMG_GPG_FPR" "${_OS} signing-key fingerprint (empty = off)?" "$_f"
  done
}

ask_build_options() {
  log "Step 6/6 — build options"
  echo "  IMG_SIZE is the host image size. Kept small on purpose: the OS uses"
  echo "  ~1.7 GB, and a small image makes the USB->internal-disk clone fast."
  ask IMG_SIZE "Image size?" "$IMG_SIZE"
  echo "  ALPINE_BRANCH is the Alpine release the host is built from (v3.22 ships"
  echo "  kernel ~6.12 — needed for recent AMD/Intel hardware)."
  ask ALPINE_BRANCH "Alpine branch?" "$ALPINE_BRANCH"
  echo "  Baking config.env into the image makes the appliance boot pre-configured."
  echo "  WARNING: config.env contains SECRETS (passwords, Wi-Fi PSK) — an image"
  echo "  built this way is SENSITIVE; do not distribute it."
  ask_yn BAKE_CONFIG "Bake config.env into the image?" "$BAKE_CONFIG"
}

# --- summary ----------------------------------------------------------------------
show_summary() {
  echo
  echo "============================ summary ============================"
  for _e in $ENVS; do
    eval "_en=\$${_e}_ENABLED"; eval "_os=\$${_e}_OS"; eval "_de=\$${_e}_DE"
    eval "_eg=\$${_e}_EGRESS_MODE"; eval "_ea=\$${_e}_EGRESS_ALLOW"; eval "_ed=\$${_e}_ENCRYPT_DISK"
    if [ "$_en" = "0" ]; then
      printf '  %-14s disabled\n' "$_e"
    else
      printf '  %-14s %s / %s, egress=%s%s, encrypt_disk=%s\n' \
        "$_e" "$_os" "$_de" "$_eg" "${_ea:+ ($_ea)}" "$_ed"
    fi
  done
  printf '  guest user     %s (password: %s)\n' "$GUEST_USER" "$(mask "$GUEST_PASSWORD")"
  printf '  host root pw   %s\n' "$(mask "$HOST_ROOT_PASSWORD")"
  if [ -n "$WIFI_SSID" ]; then
    printf '  wifi           %s (psk: %s, country %s)\n' "$WIFI_SSID" "$(mask "$WIFI_PSK")" "$WIFI_COUNTRY"
  else
    printf '  wifi           (not configured — wired, or set up later on the appliance)\n'
  fi
  printf '  usbguard=%s yubikey=%s trust_bar=%s encrypt=%s\n' \
    "$USBGUARD" "$YUBIKEY_ROUTER" "$TRUST_BAR" "$ENCRYPT"
  [ "$ENCRYPT" = "1" ] && printf '  luks pass      %s\n' "$(mask "$LUKS_PASS")"
  for _OS in UBUNTU ARCH DEBIAN; do
    eval "_d=\$${_OS}_IMG_DATE"; eval "_s=\$${_OS}_IMG_SHA256"; eval "_f=\$${_OS}_IMG_GPG_FPR"
    [ -n "$_d$_s$_f" ] && printf '  pin %-9s date=%s sha256=%s gpg=%s\n' \
      "$_OS" "${_d:--}" "${_s:+set}${_s:--unverified}" "${_f:+set}${_f:--off}"
  done
  printf '  image          size=%s alpine=%s bake_config=%s\n' "$IMG_SIZE" "$ALPINE_BRANCH" "$BAKE_CONFIG"
  echo "================================================================="
}

# --- writing ----------------------------------------------------------------------
# maybe_backup ASK(0|1): an existing config.env is never clobbered silently.
# Interactive mode asks (default: back up); refusing exits WITHOUT touching the
# old file. --defaults mode backs up automatically — non-interactive must not
# destroy data either.
maybe_backup() {
  [ -f "$CONFIG_ENV" ] || return 0
  if [ "$1" = "1" ]; then
    warn "$CONFIG_ENV already exists."
    ask_yn BACKUP "Back it up to config.env.bak-<timestamp> and replace it?" 1
    if [ "$BACKUP" != "1" ]; then
      log "Keeping the existing config.env — nothing was written."
      exit 1
    fi
  fi
  _bak="$CONFIG_ENV.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$CONFIG_ENV" "$_bak"
  ok "Existing config backed up to $_bak"
}

# write_config: atomic (temp file + mv), always 0600. config.env is SOURCED by
# every appliance script and holds the whole secret set, so a half-written or
# world-readable copy is worse than none.
write_config() {
  _tmp="$CONFIG_ENV.tmp.$$"
  TMP_FILE="$_tmp"
  ( umask 077
    {
      cat <<EOF
# config.env — generated by configure.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Sourced (executed) by every appliance script. It holds SECRETS (passwords,
# Wi-Fi PSK, LUKS passphrase): keep it 0600 and never commit it.
# Re-run ./configure.sh to change any answer; config.env.example documents
# every knob, including the ones this wizard does not ask about.

# Position in \$ENVS fixes each env's workspace, subnet and bridge — the wizard
# only toggles <env>_ENABLED; never reorder this list.
ENVS="$ENVS"
SUBNET_BASE="$SUBNET_BASE"

# --- environments (the VMs) ----------------------------------------------------
office_ENABLED=$office_ENABLED
office_OS="$office_OS"
office_DE="$office_DE"
office_EGRESS_MODE="$office_EGRESS_MODE"
office_EGRESS_ALLOW="$office_EGRESS_ALLOW"
office_ENCRYPT_DISK=$office_ENCRYPT_DISK
development_ENABLED=$development_ENABLED
development_OS="$development_OS"
development_DE="$development_DE"
development_EGRESS_MODE="$development_EGRESS_MODE"
development_EGRESS_ALLOW="$development_EGRESS_ALLOW"
development_ENCRYPT_DISK=$development_ENCRYPT_DISK
administration_ENABLED=$administration_ENABLED
administration_OS="$administration_OS"
administration_DE="$administration_DE"
administration_EGRESS_MODE="$administration_EGRESS_MODE"
administration_EGRESS_ALLOW="$administration_EGRESS_ALLOW"
administration_ENCRYPT_DISK=$administration_ENCRYPT_DISK

# --- credentials ---------------------------------------------------------------
# All three are REQUIRED explicit values (secrets are never auto-generated).
GUEST_USER="$GUEST_USER"
GUEST_PASSWORD="$GUEST_PASSWORD"
HOST_ROOT_PASSWORD="$HOST_ROOT_PASSWORD"

# --- host Wi-Fi uplink (empty SSID = wired / configure later on the appliance) -
WIFI_SSID="$WIFI_SSID"
WIFI_PSK="$WIFI_PSK"
WIFI_COUNTRY="$WIFI_COUNTRY"

# --- security toggles ----------------------------------------------------------
USBGUARD=$USBGUARD
YUBIKEY_ROUTER=$YUBIKEY_ROUTER
TRUST_BAR=$TRUST_BAR
ENCRYPT=$ENCRYPT
LUKS_PASS="$LUKS_PASS"

# --- base-image supply-chain pinning (empty = unverified download + warning) ---
UBUNTU_IMG_DATE="$UBUNTU_IMG_DATE"
UBUNTU_IMG_SHA256="$UBUNTU_IMG_SHA256"
ARCH_IMG_DATE="$ARCH_IMG_DATE"
ARCH_IMG_SHA256="$ARCH_IMG_SHA256"
DEBIAN_IMG_DATE="$DEBIAN_IMG_DATE"
DEBIAN_IMG_SHA256="$DEBIAN_IMG_SHA256"
EOF
      # <OS>_IMG_GPG_FPR is TRI-STATE in environments/create.sh: unset = feature
      # off, set = strict, EMPTY = hard refusal (blanking a pin is never a quiet
      # downgrade). So an empty answer must OMIT the line, never write ="".
      [ -n "$UBUNTU_IMG_GPG_FPR" ] && printf 'UBUNTU_IMG_GPG_FPR="%s"\n' "$UBUNTU_IMG_GPG_FPR"
      [ -n "$ARCH_IMG_GPG_FPR" ]   && printf 'ARCH_IMG_GPG_FPR="%s"\n' "$ARCH_IMG_GPG_FPR"
      [ -n "$DEBIAN_IMG_GPG_FPR" ] && printf 'DEBIAN_IMG_GPG_FPR="%s"\n' "$DEBIAN_IMG_GPG_FPR"
      cat <<EOF

# --- build options (consumed by src/build.sh) ---------------------------
IMG_SIZE="$IMG_SIZE"
ALPINE_BRANCH="$ALPINE_BRANCH"
BAKE_CONFIG=$BAKE_CONFIG
EOF
    } > "$_tmp"
    # Carry over every knob the wizard does NOT ask about, with its example
    # default. Appliance scripts dereference config keys under `set -u`, so a
    # key missing from this file crashes first boot (IMAGES_DIR did). Only
    # uncommented KEY=... lines are candidates; keys written above always win,
    # and commented-out example keys (the opt-in tri-states) stay out.
    {
      printf '\n# --- defaults carried from config.env.example (not asked by the wizard) --\n'
      grep -E '^[A-Za-z_][A-Za-z_0-9]*=' "$HERE/config.env.example" | while IFS= read -r _line; do
        _key="${_line%%=*}"
        grep -q "^$_key=" "$_tmp" || printf '%s\n' "$_line"
      done
    } >> "$_tmp"
  )
  chmod 600 "$_tmp"
  mv "$_tmp" "$CONFIG_ENV"
  TMP_FILE=""
}

next_steps() {
  cat <<EOF

config.env is written. The remaining two endpoints, in order:
  2. ./flash.sh                    # build the image and flash a USB stick
       (needs Docker running; or build by hand: ./src/build.sh)
  3. Boot the target machine from the USB — it auto-installs to the internal
     disk and powers off. Remove the stick and boot again. Then, as root on
     tty2 (Ctrl+Alt+F2):
       cd /opt/appliance && ./setup.sh   # 1) create the VMs   2) isolate + verify
EOF
}

# --- main -------------------------------------------------------------------------
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --defaults) DEFAULTS=1 ;;
  "") DEFAULTS=0 ;;
  *) usage >&2; exit 2 ;;
esac

if [ "$DEFAULTS" = "1" ]; then
  seed_defaults
  # CI/tests get a well-known placeholder password (secrets are never
  # auto-generated; "changeme" is explicit, greppable and obviously not secret).
  GUEST_PASSWORD="changeme"; HOST_ROOT_PASSWORD="changeme"
  maybe_backup 0
  write_config
  ok "Wrote $CONFIG_ENV from built-in defaults (0600)."
  exit 0
fi

cat <<'EOF'
==========================================================================
 Step 1 of 3 — configure the appliance (writes config.env).
 Empty answers keep the [defaults]; Ctrl+C aborts without writing anything.
==========================================================================
EOF

preflight
seed_defaults
ask_environments
ask_credentials
ask_network
ask_security
ask_pinning
ask_build_options

show_summary
ask_yn CONFIRM "Write config.env with these settings?" 1
if [ "$CONFIRM" != "1" ]; then
  log "Nothing written. Re-run ./configure.sh any time."
  exit 0
fi

maybe_backup 1
write_config
ok "Wrote $CONFIG_ENV (0600)."

next_steps
