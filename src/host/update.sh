#!/bin/bash
# =============================================================================
# host/update.sh — in-place update of the appliance CODE
# -----------------------------------------------------------------------------
# Without this, shipping a fix to a deployed machine means rebuilding the image,
# reflashing a stick, wiping the internal disk and losing every VM — which in
# practice means the machine in the field never gets the fix. This replaces the
# code tree at $APP_ROOT (/opt/appliance) and NOTHING else:
#
#   * config.env, the installer/first-boot markers, VM storage ($IMAGES_DIR) and
#     the libvirt domain definitions are the OPERATOR'S machine state. An update
#     replaces code, not state, so they are carried across untouched;
#   * the new tree is staged and validated (shape + shell syntax) BEFORE it is
#     swapped in: swapping in a broken tree would remove the only management
#     interface this appliance has;
#   * the swap is a rename, never a partial copy over the live tree, so there is
#     no window where half of one release is mixed with half of another;
#   * the previous tree is kept, so --rollback undoes a bad update.
#
# Signatures are mandatory: with no UPDATE_GPG_FPR pinned the update is REFUSED
# (fail closed), because "download and run as root" with no verification is a
# remote root shell for whoever can answer the URL.
#
#   host/update.sh              fetch, verify, validate, swap in, re-provision
#   host/update.sh --check      report what is available; change nothing
#   host/update.sh --rollback   restore the previous tree
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
require_root
load_config

usage() {
  cat <<'EOF'
Usage: host/update.sh [--check|--rollback]

  (no option)   fetch + verify + validate + swap in, then re-run the host scripts
  --check       report the available version and change nothing (also -n)
  --rollback    restore the most recent backup taken by a previous update

config.env keys:
  UPDATE_CHANNEL       tarball (default) | git
  UPDATE_URL           tarball URL; its detached signature is UPDATE_URL + ".sig"
  UPDATE_GIT_REMOTE    git remote (UPDATE_CHANNEL=git)
  UPDATE_GIT_REF       git tag/branch/commit to move to (default: main)
  UPDATE_GPG_FPR       pinned fingerprint of the release signing key (REQUIRED)
  UPDATE_GPG_KEYRING   optional keyring file holding that key
  UPDATE_INSECURE      1 = accept an unverified update (dangerous, off by default)
  UPDATE_KEEP_BACKUPS  how many previous trees to keep (default 3, minimum 1)
  UPDATE_BACKUP_DIR    where they are kept (default: <tree>.backups)
  UPDATE_REPROVISION   1 = re-run the host scripts after the swap (default 1)
  UPDATE_REQUIRE_VMS_OFF  1 = refuse to update while any VM is running
EOF
}

MODE="apply"
case "${1:-}" in
  ""|--apply)           MODE="apply" ;;
  --check|--dry-run|-n) MODE="check" ;;
  --rollback)           MODE="rollback" ;;
  -h|--help)            usage; exit 0 ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

LIVE="$APP_ROOT"
PARENT="$(dirname "$LIVE")"
# Default the backups next to the tree rather than in a fixed shared directory:
# it is on the same filesystem (so the swap stays a rename) and it can never mix
# up two appliance trees living under the same parent.
BACKUPS="${UPDATE_BACKUP_DIR:-$LIVE.backups}"
KEEP="${UPDATE_KEEP_BACKUPS:-3}"
case "$KEEP" in ''|*[!0-9]*) KEEP=3 ;; esac
[ "$KEEP" -ge 1 ] || KEEP=1          # a rollback needs at least the previous tree
CHANNEL="${UPDATE_CHANNEL:-tarball}"
REPROVISION="${UPDATE_REPROVISION:-1}"

# State that belongs to THIS machine and must survive a code swap.
#   .installed-system  — its absence makes the first-boot service believe it is
#                        the USB installer and re-wipe the internal disk. Losing
#                        this file on an update would destroy every VM.
#   .firstboot-done    — without it first boot re-runs provisioning at every boot.
#   .config-baked      — tells the installer the shipped config.env is deliberate.
#   config.env         — the operator's configuration AND all of the secrets.
PRESERVE=".installed-system .firstboot-done .config-baked config.env"

# --- audit (CONTRACT B) ------------------------------------------------------
# audit_event lives in lib/common.sh. An appliance still running an older lib
# must remain updatable — that is the whole point of this script — so a missing
# helper degrades to a no-op instead of aborting the update.
audit() {
  command -v audit_event >/dev/null 2>&1 || return 0
  audit_event "$@" >/dev/null 2>&1 || true
}
# CONTRACT B values carry no whitespace: fold anything that could.
sane() { printf '%s' "${1:-unknown}" | tr '[:space:]' '_'; }

file_sum() {
  [ -f "$1" ] || { printf 'absent'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else cksum "$1" | cut -d' ' -f1; fi
}

# tree_version DIR — the release identity of a tree, for --check and the audit
# log. A VERSION file is authoritative; a git checkout describes itself.
tree_version() {
  if [ -r "$1/VERSION" ]; then
    sane "$(head -1 "$1/VERSION")"
  elif [ -d "$1/.git" ] && command -v git >/dev/null 2>&1; then
    sane "$(git -C "$1" describe --always --dirty --tags 2>/dev/null || echo unknown)"
  else
    printf 'unknown'
  fi
}

# --- single-writer lock ------------------------------------------------------
# mkdir is the atomic primitive available everywhere (no flock on busybox).
LOCKDIR="/run/appliance/update.lock"
STAGE=""
cleanup() {
  [ -z "$STAGE" ] || rm -rf "$STAGE" 2>/dev/null || true
  rm -rf "$LOCKDIR" 2>/dev/null || true
  :
}
take_lock() {
  mkdir -p /run/appliance
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    _pid="$(cat "$LOCKDIR/pid" 2>/dev/null || echo '')"
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
      die "another update is already running (pid $_pid)."
    fi
    # A machine that lost power mid-update must not be locked out of updating
    # forever, so a lock whose owner is gone is stale and gets cleared.
    warn "clearing a stale update lock (pid ${_pid:-unknown} is gone)"
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || die "cannot create $LOCKDIR"
  fi
  trap cleanup EXIT INT TERM
  printf '%s\n' "$$" > "$LOCKDIR/pid"
}

# --- refuse while the machine is mid-operation -------------------------------
guard_busy() {
  # Cheap and decisive: an environment script running right now is writing the
  # very files this update is about to replace under it.
  _ps="$( { ps -eo args 2>/dev/null || ps ax 2>/dev/null || true; } | \
          grep -E 'environments/(create|isolate|vpn)\.sh|installer/install-to-disk\.sh' | \
          grep -v grep || true )"
  [ -z "$_ps" ] || die "an environment operation is in flight — wait for it to finish."

  command -v virsh >/dev/null 2>&1 || return 0
  _vms="$(LIBVIRT_DEFAULT_URI=qemu:///system virsh -q list --state-running --name 2>/dev/null \
          | sed '/^$/d' | tr '\n' ' ' | sed 's/ *$//')"
  [ -n "$_vms" ] || return 0
  if [ "${UPDATE_REQUIRE_VMS_OFF:-0}" = "1" ]; then
    die "VMs are running ($_vms) and UPDATE_REQUIRE_VMS_OFF=1 — shut them down first."
  fi
  # Not fatal: the update never touches VM disks or domain XML. But the kiosk
  # session is reconfigured afterwards, so the operator should know.
  warn "VMs are running: $_vms"
  warn "Their disks and domain definitions are NOT touched, but the desktop is reloaded."
}

# --- VM storage must not live inside the tree we are about to rename ---------
guard_images_dir() {
  _live_real="$(readlink -f "$LIVE" 2>/dev/null || printf '%s' "$LIVE")"
  _img="${IMAGES_DIR:-/var/lib/libvirt/images}"
  _img_real="$(readlink -f "$_img" 2>/dev/null || printf '%s' "$_img")"
  case "$_img_real/" in
    "$_live_real"/*)
      die "IMAGES_DIR ($_img) is inside $LIVE. An update RENAMES that tree, which
    would move every VM disk out from under libvirt. Move IMAGES_DIR to its own
    path (e.g. /var/lib/libvirt/images) and re-run." ;;
  esac
}

# --- signature verification --------------------------------------------------
norm_fpr() { printf '%s' "${1:-}" | tr -d ' :' | tr '[:lower:]' '[:upper:]'; }

# The pinned fingerprint may be the primary key while the signature came from a
# signing subkey (or the reverse), so match it against every field of VALIDSIG —
# gpg prints both the signing key and the primary key on that line.
validsig_has_fpr() {
  grep '^\[GNUPG:\] VALIDSIG ' "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"
}

# No pinned key: refuse, unless the operator has explicitly accepted the risk.
insecure_or_die() {
  if [ "${UPDATE_INSECURE:-0}" = "1" ]; then
    warn "###############################################################"
    warn "UPDATE_INSECURE=1 — installing UNVERIFIED code as root."
    warn "Whoever can answer that URL (or MITM it) now owns this appliance."
    warn "Pin UPDATE_GPG_FPR instead. This is not a supported configuration."
    warn "###############################################################"
    return 0
  fi
  die "UPDATE_GPG_FPR is empty — refusing an unverified update (fail closed).
    Pin the release signing key's fingerprint in config.env, or set
    UPDATE_INSECURE=1 if you truly accept running unsigned code as root."
}

# verify_detached FILE SIGFILE — die unless FILE is signed by the pinned key.
verify_detached() {
  _fpr="$(norm_fpr "${UPDATE_GPG_FPR:-}")"
  [ -n "$_fpr" ] || { insecure_or_die; return 0; }
  require_cmds gpg
  [ -s "$2" ] || die "no detached signature at $UPDATE_URL.sig — refusing."
  _st="$STAGE/gpg-status.txt"
  _rc=0
  if [ -n "${UPDATE_GPG_KEYRING:-}" ]; then
    gpg --batch --no-default-keyring --keyring "$UPDATE_GPG_KEYRING" \
        --status-fd 3 --verify "$2" "$1" 3>"$_st" >/dev/null 2>>"$_st" || _rc=$?
  else
    gpg --batch --status-fd 3 --verify "$2" "$1" 3>"$_st" >/dev/null 2>>"$_st" || _rc=$?
  fi
  if [ "$_rc" -ne 0 ]; then
    sed 's/^/    /' "$_st" >&2 || true
    audit update result=refused reason=bad-signature channel="$(sane "$CHANNEL")"
    die "signature verification FAILED — refusing the update."
  fi
  # gpg exits 0 for a good signature by ANY key it trusts; the pin is what makes
  # this an update channel rather than "anyone with a key can push code".
  if ! validsig_has_fpr "$_st" "$_fpr"; then
    sed 's/^/    /' "$_st" >&2 || true
    audit update result=refused reason=wrong-key channel="$(sane "$CHANNEL")"
    die "signed, but not by the pinned key $_fpr — refusing the update."
  fi
  ok "Signature verified against pinned key $_fpr"
}

# --- fetch -------------------------------------------------------------------
fetch_url() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
  else
    wget -q -O "$2" "$1"
  fi
}

# stage_tarball DEST — download, verify, unpack into DEST.
stage_tarball() {
  [ -n "${UPDATE_URL:-}" ] || die "UPDATE_CHANNEL=tarball but UPDATE_URL is empty."
  # Transport MUST be encrypted (T-15 / SO-10). The detached signature already
  # guarantees integrity + authenticity, but plaintext HTTP leaks which release a
  # machine runs (a fingerprinting/targeting aid) and lets an on-path attacker
  # strip the .sig fetch or feed a downgrade. Refuse anything but https.
  case "$UPDATE_URL" in
    https://*) : ;;
    *) audit update result=refused reason=insecure-transport
       die "UPDATE_URL must be https:// — the update transport must be encrypted (T-15). Got: $UPDATE_URL" ;;
  esac
  require_cmds tar
  _tar="$STAGE/update.tar"
  log "Downloading $UPDATE_URL ..."
  fetch_url "$UPDATE_URL" "$_tar" || { audit update result=refused reason=download; die "download failed: $UPDATE_URL"; }
  [ -s "$_tar" ] || { audit update result=refused reason=empty-download; die "downloaded an empty file from $UPDATE_URL"; }

  if [ -n "$(norm_fpr "${UPDATE_GPG_FPR:-}")" ]; then
    log "Downloading $UPDATE_URL.sig ..."
    fetch_url "$UPDATE_URL.sig" "$STAGE/update.sig" \
      || { audit update result=refused reason=no-signature; die "no signature at $UPDATE_URL.sig — refusing."; }
  fi
  verify_detached "$_tar" "$STAGE/update.sig"

  mkdir -p "$DEST_X"
  # -f without an explicit compression flag: both GNU and busybox tar sniff
  # gzip/xz/bzip2, so a release can change compression without breaking updates.
  tar -xf "$_tar" -C "$DEST_X" || die "the downloaded archive could not be unpacked."
}

# stage_git DEST — fetch the configured ref, verify its signature, check it out.
stage_git() {
  require_cmds git
  [ -n "${UPDATE_GIT_REMOTE:-}" ] || die "UPDATE_CHANNEL=git but UPDATE_GIT_REMOTE is empty."
  _ref="${UPDATE_GIT_REF:-main}"
  log "Fetching $_ref from $UPDATE_GIT_REMOTE ..."
  git init -q "$DEST_X"
  git -C "$DEST_X" remote add origin "$UPDATE_GIT_REMOTE"
  git -C "$DEST_X" fetch -q --depth 1 origin "$_ref" || die "git fetch of $_ref failed."
  # Fetch the tag OBJECT as well: a signed annotated tag is how releases are
  # normally signed, and a shallow ref fetch alone leaves nothing to verify.
  git -C "$DEST_X" fetch -q --depth 1 origin "refs/tags/$_ref:refs/tags/$_ref" 2>/dev/null || true
  git -C "$DEST_X" checkout -q --detach FETCH_HEAD || die "git checkout of $_ref failed."

  _fpr="$(norm_fpr "${UPDATE_GPG_FPR:-}")"
  if [ -z "$_fpr" ]; then insecure_or_die; return 0; fi
  require_cmds gpg
  _st="$STAGE/git-status.txt"; _rc=0
  if git -C "$DEST_X" rev-parse -q --verify "refs/tags/$_ref" >/dev/null 2>&1; then
    git -C "$DEST_X" verify-tag --raw "$_ref" > "$_st" 2>&1 || _rc=$?
  else
    git -C "$DEST_X" verify-commit --raw HEAD > "$_st" 2>&1 || _rc=$?
  fi
  if [ "$_rc" -ne 0 ] || ! validsig_has_fpr "$_st" "$_fpr"; then
    sed 's/^/    /' "$_st" >&2 || true
    audit update result=refused reason=bad-signature channel=git
    die "$_ref is not signed by the pinned key $_fpr — refusing the update."
  fi
  ok "Git signature verified against pinned key $_fpr"
}

# --- validation --------------------------------------------------------------
# resolve_tree DIR — the extracted content, allowing for the single wrapper
# directory that `git archive`/GitHub tarballs put around everything.
resolve_tree() {
  if [ -e "$1/setup-machine.sh" ]; then printf '%s' "$1"; return 0; fi
  _n=0; _only=""
  for _e in "$1"/*; do
    [ -e "$_e" ] || continue
    _n=$((_n+1)); _only="$_e"
  done
  if [ "$_n" = 1 ] && [ -d "$_only" ]; then printf '%s' "$_only"; return 0; fi
  printf '%s' "$1"
}

# validate_tree DIR — everything that must hold BEFORE we swap this in. A tree
# that fails here is thrown away and the live tree is never touched.
validate_tree() {
  _d="$1"; _bad=0
  for _p in src/lib/common.sh src/host src/environments setup-machine.sh; do
    [ -e "$_d/$_p" ] || { warn "staged tree has no $_p — this is not an appliance tree"; _bad=1; }
  done
  [ "$_bad" = 0 ] || return 1
  # Not fatal, but an update that drops the updater strands the machine.
  [ -e "$_d/src/host/update.sh" ] || warn "the new tree has no src/host/update.sh — it could not be updated again."

  # Syntax-check every script with the interpreter its shebang actually names:
  # the host scripts are bash and would fail a busybox-ash parse for reasons
  # that have nothing to do with them being broken.
  find "$_d" -type f -name '*.sh' -print > "$STAGE/scripts.lst"
  while IFS= read -r _f; do
    case "$(head -1 "$_f" 2>/dev/null)" in
      *bash*) _sh="bash" ;;
      *)      _sh="sh" ;;
    esac
    command -v "$_sh" >/dev/null 2>&1 || _sh="sh"
    if ! "$_sh" -n "$_f" 2>"$STAGE/syntax.err"; then
      warn "syntax error in ${_f#"$_d"/}:"
      sed 's/^/    /' "$STAGE/syntax.err" >&2 || true
      _bad=1
    fi
  done < "$STAGE/scripts.lst"
  [ "$_bad" = 0 ]
}

# carry_state DIR — move this machine's state into the tree about to go live.
carry_state() {
  for _p in $PRESERVE; do
    [ -e "$LIVE/$_p" ] || continue
    # A release tarball must never win over the live file — especially not
    # config.env, which would replace the operator's secrets with a build
    # machine's, or blank them entirely.
    rm -rf "${1:?}/$_p"
    cp -a "$LIVE/$_p" "$1/$_p"
  done
  if [ -e "$1/config.env" ]; then
    chmod 600 "$1/config.env"
  elif [ -e "$LIVE/config.env" ]; then
    die "internal error: config.env was not carried into the new tree — aborting."
  fi
  # A tarball can carry any ownership/mode; the tree runs as root, so the kiosk
  # user must not be able to write to any of it.
  chown -R root:root "$1" 2>/dev/null || true
  chmod -R go-w "$1" 2>/dev/null || true
  chmod +x "$1"/src/*/*.sh "$1/setup-machine.sh" 2>/dev/null || true
}

prune_backups() {
  [ -d "$BACKUPS" ] || return 0
  _n="$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [ "$_n" -gt "$KEEP" ] || return 0
  # Names are UTC timestamps, so lexical order is chronological order.
  find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | sort | head -n "$((_n - KEEP))" \
    | while IFS= read -r _old; do rm -rf "$_old"; done
}

# swap_in NEWTREE — atomically make NEWTREE the live tree, keeping the old one.
# Prints the backup path on stdout.
swap_in() {
  mkdir -p "$BACKUPS"; chmod 700 "$BACKUPS"
  _bak="$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)"
  # Two updates inside the same second must not collide (the tests do exactly
  # that, and so does an operator re-running after a quick fix).
  if [ -e "$_bak" ]; then _bak="$_bak.$$"; fi
  mv "$LIVE" "$_bak" || die "could not move the current tree aside — nothing changed."
  if ! mv "$1" "$LIVE"; then
    # Never leave the appliance with no tree at all.
    mv "$_bak" "$LIVE" || die "CRITICAL: the tree is at $_bak and could not be restored to $LIVE."
    die "could not swap the new tree in — the previous tree was restored."
  fi
  printf '%s' "$_bak"
}

# --- post-swap re-provisioning ----------------------------------------------
# Same order and same resilience as the first-boot service in build/make-image.sh:
# each step runs independently so one failure cannot wedge the machine. Executed
# directly (not via `sh`) so each script's own shebang picks its interpreter.
reprovision() {
  if [ "$REPROVISION" = "0" ]; then
    warn "UPDATE_REPROVISION=0 — new code is in place but not applied yet."
    warn "Run host/detect-and-install.sh, configure.sh, harden.sh, switching.sh to apply it."
    return 0
  fi
  log "Re-running the host scripts so the new code takes effect ..."
  "$LIVE/host/detect-and-install.sh" || warn "host/detect-and-install failed"
  "$LIVE/host/configure.sh"          || warn "host/configure failed"
  "$LIVE/host/harden.sh"             || warn "host/harden failed"
  "$LIVE/host/switching.sh"          || warn "host/switching failed"
}

# verify_state_intact BACKUP — the update replaces code, not machine state.
# Checked rather than assumed: a bad release could ship its own config.env and
# silently hand the operator someone else's secrets.
verify_state_intact() {
  if [ "$(file_sum "$LIVE/config.env")" != "$CFG_SUM" ]; then
    warn "config.env differs after the swap — restoring the operator's copy."
    cp -a "$1/config.env" "$LIVE/config.env" && chmod 600 "$LIVE/config.env"
  fi
  for _p in .installed-system .firstboot-done .config-baked; do
    if [ -e "$1/$_p" ] && [ ! -e "$LIVE/$_p" ]; then
      warn "$_p was lost in the swap — restoring it."
      cp -a "$1/$_p" "$LIVE/$_p"
    fi
  done
}

# =============================================================================
# main
# =============================================================================
CFG_SUM="$(file_sum "$LIVE/config.env")"
CUR_VER="$(tree_version "$LIVE")"

if [ "$MODE" = "rollback" ]; then
  take_lock
  guard_busy
  [ -d "$BACKUPS" ] || die "no backups in $BACKUPS — nothing to roll back to."
  PREV="$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
  [ -n "$PREV" ] || die "no backups in $BACKUPS — nothing to roll back to."
  STAGE="$(mktemp -d "$PARENT/.appliance-update.XXXXXX")"
  # Validate the backup too: it may be the tree that a partial update left broken.
  validate_tree "$PREV" || die "the backup at $PREV does not validate — refusing to restore it."
  RESTORE="$STAGE/tree"
  mv "$PREV" "$RESTORE"
  carry_state "$RESTORE"
  PREV_VER="$(tree_version "$RESTORE")"
  log "Rolling back $CUR_VER -> $PREV_VER"
  BAK="$(swap_in "$RESTORE")"
  verify_state_intact "$BAK"
  prune_backups
  ok "Rolled back to $PREV_VER (previous tree kept at $BAK)"
  audit update result=rolled-back "from=$(sane "$CUR_VER")" "to=$(sane "$PREV_VER")"
  reprovision
  exit 0
fi

take_lock
guard_busy
guard_images_dir
STAGE="$(mktemp -d "$PARENT/.appliance-update.XXXXXX")"
DEST_X="$STAGE/x"

case "$CHANNEL" in
  tarball) stage_tarball ;;
  git)     stage_git ;;
  *)       die "unknown UPDATE_CHANNEL '$CHANNEL' (expected tarball or git)." ;;
esac

NEW="$(resolve_tree "$DEST_X")"
if ! validate_tree "$NEW"; then
  audit update result=refused reason=invalid-tree channel="$(sane "$CHANNEL")"
  die "the staged tree failed validation — the live tree was NOT touched."
fi
NEW_VER="$(tree_version "$NEW")"

if [ "$MODE" = "check" ]; then
  printf 'channel:   %s\n' "$CHANNEL"
  printf 'current:   %s\n' "$CUR_VER"
  printf 'available: %s\n' "$NEW_VER"
  if [ "$CUR_VER" = "$NEW_VER" ] && [ "$CUR_VER" != "unknown" ]; then
    ok "Already up to date (nothing was changed)."
  else
    ok "An update is available (nothing was changed — re-run without --check to apply)."
  fi
  audit update result=checked "from=$(sane "$CUR_VER")" "to=$(sane "$NEW_VER")" channel="$(sane "$CHANNEL")"
  exit 0
fi

carry_state "$NEW"
log "Applying $CUR_VER -> $NEW_VER"
BAK="$(swap_in "$NEW")"
verify_state_intact "$BAK"
prune_backups
ok "Updated to $NEW_VER (previous tree kept at $BAK — 'host/update.sh --rollback' undoes this)"
audit update result=applied "from=$(sane "$CUR_VER")" "to=$(sane "$NEW_VER")" channel="$(sane "$CHANNEL")"
reprovision
ok "Update complete."
