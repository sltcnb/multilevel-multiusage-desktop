#!/bin/bash
# =============================================================================
# src/environments.sh — the per-environment (guest VM) operations, one dispatcher.
# -----------------------------------------------------------------------------
# Merged from the former src/environments/*.sh. Usage:
#   src/environments.sh <command> [args...]
# Commands: create | isolate | vpn | diode | guest-doctor |
#           set-guest-password | scrub-secrets
# Normally reached through ./setup.sh (steps 1,2,3,4,5,7,11); runnable directly.
# bash because several commands need it (create/diode/isolate use bash string
# ops); bash is installed on the appliance and the build host alike. Each
# command's body is the former standalone script, verbatim down to its own
# `set -e...` line; only its shebang and `. ../lib/...` sourcing are dropped —
# this file sources the shared library once, below, and each command exits on
# its own.
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

_env_usage() {
  cat >&2 <<'U'
Usage: src/environments.sh <command> [args...]
  create               create the enabled guest VMs
  isolate              build + verify inter-environment isolation
  vpn                  per-environment WireGuard VPN
  diode                PA-114 §3.18 inter-domain file diode
  guest-doctor         diagnose / repair a guest from the host
  set-guest-password   set a guest's login password
  scrub-secrets        blank consumed secrets in config.env
U
}

_cmd="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$_cmd" in
create)
# =============================================================================
# environments/create.sh
# -----------------------------------------------------------------------------
# Create the three VMs with virt-install:
#   desktop  -> Ubuntu cloud image + cloud-init (unattended)
#   devops   -> Arch  (prebuilt Arch cloud image + cloud-init — see prose)
#   analysis -> Arch  (same)
#
# Auto-computed vCPU/RAM/disk (from config.env). host-passthrough CPU mode.
# Each VM attached to its OWN isolated network. virsh autostart on all three.
#
# NOTE: this script ENSURES each isolated network exists (idempotent) so VMs can
# attach. environments/isolate.sh owns the authoritative network definitions,
# the nftables inter-VM DROP rules, and the verification test. Running 03 before
# 05 is fine; 05 re-applies/repairs.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
# shellcheck source=lib.sh
# shellcheck source=lib.sh
# shellcheck source=lib.sh
require_root
load_config
require_cmds virt-install virsh qemu-img wget openssl sha256sum sha512sum gpg

mkdir -p "$IMAGES_DIR" "$CACHE_DIR"

# -----------------------------------------------------------------------------
# Tunable image sources (OVERRIDABLE).
#   <OS>_IMG_DATE pins the DATED directory each vendor publishes next to its
#   rolling one. The rolling paths ("current"/"latest") re-point at a new build
#   every few weeks, which is exactly why hand-pinned hashes went stale and
#   operators stopped pinning at all. A dated directory is immutable, so a hash
#   (or a vendor signature) pinned against it keeps verifying until YOU move it.
#   Empty (default) = today's rolling behaviour. Use the vendor's own directory
#   name, verbatim — they don't agree on a format:
#     UBUNTU_IMG_DATE="20260701"          -> .../jammy/20260701/
#     DEBIAN_IMG_DATE="20260722-2547"     -> .../bookworm/20260722-2547/
#     ARCH_IMG_DATE="v20260715.556894"    -> .../images/v20260715.556894/
# -----------------------------------------------------------------------------
: "${UBUNTU_IMG_DATE:=}"
: "${ARCH_IMG_DATE:=}"
: "${DEBIAN_IMG_DATE:=}"
: "${UBUNTU_IMG_URL:=https://cloud-images.ubuntu.com/jammy/${UBUNTU_IMG_DATE:-current}/jammy-server-cloudimg-amd64.img}"
# Arch publishes an official cloud image (qcow2) that ships cloud-init.
: "${ARCH_IMG_URL:=https://geo.mirror.pkgbuild.com/images/${ARCH_IMG_DATE:-latest}/Arch-Linux-x86_64-cloudimg.qcow2}"
# Debian official genericcloud qcow2 (bookworm) — ships cloud-init.
: "${DEBIAN_IMG_URL:=https://cloud.debian.org/images/cloud/bookworm/${DEBIAN_IMG_DATE:-latest}/debian-12-genericcloud-amd64.qcow2}"

# -----------------------------------------------------------------------------
# Windows 11 office guest (OS=windows). Unlike the Linux guests there is NO
# cloud image and NO cloud-init: Windows installs from an ISO YOU supply, driven
# by an autounattend.xml this repo generates (see lib/windows-unattend.sh). This
# repo can neither download nor license Windows, so WINDOWS_ISO is REQUIRED and
# has no default — create.sh fails closed with guidance if OS=windows and it is
# unset. virtio-win (drivers + qemu-guest-agent) and the SPICE guest tools
# (spice-vdagent, for viewer auto-resize) ARE freely redistributable and are
# fetched automatically.
: "${WINDOWS_ISO:=}"                        # REQUIRED for OS=windows: path to a
                                            # Windows 11 install ISO (operator-supplied).
: "${VIRTIO_WIN_URL:=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
: "${VIRTIO_WIN_SHA256:=}"                  # optional pin, same model as *_IMG_SHA256.
: "${SPICE_GUEST_TOOLS_URL:=https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe}"
: "${WIN_LOCALE:=en-US}"                    # Windows install locale.
: "${WIN_TZ:=UTC}"                          # Windows time zone (matches the appliance).

# -----------------------------------------------------------------------------
# Base image integrity pinning (OPTIONAL but recommended — supply-chain).
#   The URLs above are plain HTTPS to third-party mirrors/CDNs with no
#   signature check of their own; a compromised mirror, a MITM, or a stale/
#   poisoned local cache would otherwise be trusted blindly. fetch() below
#   FAILS CLOSED: it refuses to use ANY image (fresh download OR already
#   cached) that does not verify.
#   There are two ways to make it verify, and they compose:
#     1. <OS>_IMG_GPG_FPR  — the vendor's OWN signature, checked automatically
#        (see below). Survives a vendor rebuild, so it does not go stale.
#     2. <OS>_IMG_SHA256   — a specific 64-hex-char digest you pin by hand. This
#        is the STRONGER statement (it pins WHICH build, not just "signed by the
#        vendor"), so it WINS: when set, the signature path is skipped entirely.
#        Pair it with <OS>_IMG_DATE above or it goes stale on the next rebuild.
# Both empty/unset -> the image downloads with no integrity check at all (a
# warning is printed). REQUIRE_IMG_SHA256=1 makes that a hard error.
: "${UBUNTU_IMG_SHA256:=}"
: "${ARCH_IMG_SHA256:=}"
: "${DEBIAN_IMG_SHA256:=}"

# -----------------------------------------------------------------------------
# Vendor signature pinning for the base images (same trust model as the apt-key
# fingerprints below): fetch what the vendor signed, and refuse it unless the
# signature was made by EXACTLY the pinned key. That closes the hole a bare
# `gpg --verify` leaves open — gpg exits 0 for a good signature from ANY key it
# happens to have, so the fingerprint comparison is what actually gates trust.
#
# TRI-STATE, on purpose:
#   * variable NOT SET   -> feature off; today's behaviour (unverified download
#                           + the warning). This is the default.
#   * set to a fpr       -> STRICT. A missing//bad/foreign signature deletes the
#                           image and aborts.
#   * set to EMPTY ("")  -> REFUSED. Blanking a pin is never a quiet downgrade
#                           path (same rule as MS_GPG_FPR/WAZUH_GPG_FPR). Note
#                           this needs `${VAR+set}`, not `${VAR:-}`: the latter
#                           cannot tell "unset" from "deliberately blanked".
#   Consequence: to keep the feature off, leave the key OUT of config.env or
#   comment it out — do NOT write <OS>_IMG_GPG_FPR="".
#
# NO DEFAULTS ARE SHIPPED. A fingerprint baked in by this repo would just move
# the trust problem into git; obtain each vendor's key fingerprint out of band
# (vendor documentation over an independent path, a distro keyring package,
# your own escrow) and paste it into config.env yourself:
#   Ubuntu: Canonical cloud-image signing key  (cloud-images.ubuntu.com docs)
#   Debian: Debian cloud-images signing key    (wiki.debian.org/Cloud/)
#   Arch:   the Arch developer key that signed the image (see the .sig)
: "${IMG_GPG_KEYRING:=}"            # exported key(s) placed here out of band —
                                    # preferred: no network trust at all.
: "${IMG_GPG_KEYSERVER:=hkps://keyserver.ubuntu.com}"   # fallback: --recv-keys
                                    # BY FINGERPRINT. Safe only because the
                                    # fingerprint is the pin; a hostile
                                    # keyserver cannot answer with another key.

# -----------------------------------------------------------------------------
# Pinned GPG fingerprints for third-party apt repos installed INSIDE guests
# (Microsoft Intune/Edge, Wazuh agent — see make_seed below). The upstream
# `curl ... | gpg --dearmor` pattern trusts ANY key served at that URL with no
# verification; a compromised CDN/mirror or MITM could swap in an attacker key
# whose packages the guest would then trust. FAIL CLOSED: the cloud-init
# runcmd re-checks the ACTUALLY downloaded key's fingerprint against these
# before dearmoring it, and aborts that integration (no keyring written, repo
# not added, package not installed) on any mismatch. require_pinned_fpr()
# additionally refuses to build the seed at all if a needed one is blanked
# out. Defaults are the vendors' current, well-known, long-lived signing-key
# fingerprints (verified independently) — override only if a vendor rotates
# its key, and verify the new one out-of-band first.
# `${VAR-default}` and NOT `${VAR:=default}`: the := form also substitutes when
# the variable is set but EMPTY, so an operator who deliberately blanks a
# fingerprint in config.env had it silently replaced by the default again and
# require_pinned_fpr below could never fire — the documented fail-closed guard
# was unreachable. With `-`, an explicit empty value survives and is refused.
MS_GPG_FPR="${MS_GPG_FPR-BC528686B50D79E339D3721CEB3E94ADBE1229CF}"
WAZUH_GPG_FPR="${WAZUH_GPG_FPR-0DCFCA5547B19D2A6099506096B3EE5F29111145}"

# -----------------------------------------------------------------------------
# Custom APT source (OPTIONAL — applies to apt-family guests: ubuntu/debian).
#   APT_MIRROR : base mirror URL that REPLACES the image's default distro
#                archive (e.g. an internal mirror or a pull-through cache).
#                Wired through cloud-init's apt.primary, so it also covers the
#                suite's security/updates pockets — not just the initial fetch.
#   APT_PROXY  : caching HTTP(S) proxy for apt, e.g. an apt-cacher-ng instance
#                reachable on the isolated net (http://10.20.30.1:3142). Set as
#                the GLOBAL apt Acquire proxy, so it ALSO transparently covers
#                the third-party repos added inside the guest (Microsoft, Wazuh).
#   Both EMPTY -> guests keep their image's built-in upstream mirrors (default
#                behavior, nothing changes). Arch guests ignore these (pacman).
#   These only reroute WHERE packages come from; the third-party GPG-fingerprint
#   pinning above still gates WHAT is trusted, so a hostile mirror/proxy cannot
#   substitute keys.
# -----------------------------------------------------------------------------
: "${APT_MIRROR:=}"
: "${APT_PROXY:=}"

# require_pinned_fpr VARNAME LABEL — fail closed if a pinned fingerprint the
# current config actually needs was blanked out.
require_pinned_fpr() {
  eval "[ -n \"\${${1}:-}\" ]" || die "$1 is empty — refusing to install $2 without a pinned GPG fingerprint (see config.env.example)."
}

# --- vendor-key helpers (same VALIDSIG technique as host/update.sh) -----------
norm_fpr() { printf '%s' "${1:-}" | tr -d ' :' | tr '[:lower:]' '[:upper:]'; }

# The pinned fingerprint may be the primary key while the signature came from a
# signing subkey (or the reverse), so match it against every field of VALIDSIG —
# gpg prints both the signing key and the primary key on that line. This gate is
# what actually carries the trust: `gpg --verify` exits 0 for a good signature
# from ANY key it happens to have, so exit status alone proves nothing.
validsig_has_fpr() {
  grep '^\[GNUPG:\] VALIDSIG ' "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"
}

# img_gpg_fpr OSKEY — print the normalized <OSKEY>_IMG_GPG_FPR pin, or nothing
# when vendor-signature checking is OFF for that OS. TRI-STATE (see the config
# block above): unset -> off; set-but-EMPTY -> die (blanking a pin is a refused
# downgrade, same rule as MS_GPG_FPR); set -> normalized fingerprint. Needs
# ${VAR+set} and NOT ${VAR:-}: the latter cannot tell "unset" from "deliberately
# blanked". Note there are deliberately NO `: "${<OS>_IMG_GPG_FPR:=}"` defaults
# at the top of this script — := would turn "unset" into "set-but-empty" and
# make this guard fire on every default install.
img_gpg_fpr() {
  _igf_var="${1}_IMG_GPG_FPR"
  eval "_igf_isset=\${${_igf_var}+yes}"
  [ -n "${_igf_isset:-}" ] || return 0
  eval "_igf_fpr=\${${_igf_var}:-}"
  [ -n "$_igf_fpr" ] || die "$_igf_var is set but EMPTY — blanking a GPG pin is a refused downgrade. To turn vendor-signature checking OFF, remove or comment out $_igf_var in config.env instead (see the header comment in environments/create.sh)."
  norm_fpr "$_igf_fpr"
}

# -----------------------------------------------------------------------------
# Guest password: a value the operator chose in config.env (never auto-generated
# — see require_secret). make_seed hands it to the guest twice: as a SHA512-crypt
# hash in users[].passwd (the canonical cloud-init form) and via the chpasswd
# binary in runcmd (covers root too). The chpasswd cloud-config key is NOT used:
# its list/users dialects are mutually exclusive across cloud-init versions.
# -----------------------------------------------------------------------------
GUEST_PASSWORD="$(require_secret GUEST_PASSWORD)"

# env_guest_password ENV — the login/root password for THIS environment. Prefer a
# per-env secret (<ENV>_GUEST_PASSWORD in config.env), else fall back to the
# global GUEST_PASSWORD. Distinct per-domain secrets are what break the SO-1
# pivot: with ONE shared value present on every domain, recovering it in the
# least-trusted environment hands the attacker the most-trusted one (and root).
# Set e.g. administration_GUEST_PASSWORD to a value used NOWHERE else. Never
# auto-generated (see require_secret): an unset per-env var simply inherits the
# global, so existing single-password installs behave exactly as before.
env_guest_password() {
  _egp="$(env_val "$1" GUEST_PASSWORD)"
  [ -n "$_egp" ] && printf '%s' "$_egp" || printf '%s' "$GUEST_PASSWORD"
}

# -----------------------------------------------------------------------------
# ensure_net NAME BRIDGE SUBNET  — define+start an ISOLATED NAT network.
#   forward mode 'nat' gives outbound internet; each net has its own bridge and
#   its own /24 so guests are on separate L2 segments. 05 adds nftables to block
#   inter-net L3 forwarding (defense-in-depth).
# -----------------------------------------------------------------------------
ensure_net() {
  name="$1"; bridge="$2"; subnet="$3"
  if virsh net-info "$name" >/dev/null 2>&1; then
    log "Network $name exists."
  else
    log "Defining isolated network $name ($bridge, ${subnet}.0/24) ..."
    tmpxml="$(mktemp)"
    cat > "$tmpxml" <<EOF
<network>
  <name>$name</name>
  <forward mode='nat'/>
  <bridge name='$bridge' stp='on' delay='0'/>
  <ip address='${subnet}.1' netmask='255.255.255.0'>
    <dhcp><range start='${subnet}.2' end='${subnet}.254'/></dhcp>
  </ip>
</network>
EOF
    run virsh net-define "$tmpxml"
    rm -f "$tmpxml"
  fi
  virsh net-start "$name" >/dev/null 2>&1 || true
  virsh net-autostart "$name" >/dev/null 2>&1 || true
}

# Ensure an isolated network for every ENABLED environment (index -> subnet).
for_each_enabled_env | while read -r env idx; do
  ensure_net "$(env_net "$env")" "$(env_bridge "$env" "$idx")" "$(env_subnet "$env" "$idx")"
done

# -----------------------------------------------------------------------------
# make_seed VMNAME HOSTNAME  -> path to a cloud-init NoCloud seed ISO.
#   Works for BOTH Ubuntu and Arch cloud images (both bundle cloud-init).
# -----------------------------------------------------------------------------
make_seed() {
  vm="$1"; host="$2"
  seed_dir="$CACHE_DIR/seed-$vm"
  mkdir -p "$seed_dir"
  # user-data carries the guest+root passwords in PLAINTEXT. $CACHE_DIR defaults
  # to /var/cache/appliance-build (mkdir 0755) and `cat >` writes 0644, so any
  # local account — including the unprivileged kiosk desktop user — could read
  # them. Lock the dir to root-only and write the seed files under umask 077;
  # the plaintext user-data is shredded once the ISO is built (below).
  chmod 700 "$seed_dir" 2>/dev/null || true

  # Guest password, prepared for the TWO version-proof paths below:
  #   _pw_hash — a SHA512-CRYPT hash ($6$...) for users[].passwd, THE canonical
  #     cloud-init password form, accepted by every version on Ubuntu/Debian/
  #     Arch. MUST come from `openssl passwd -6`: a bare sha512sum hex digest
  #     is NOT a crypt hash — that is what cloud-init rejected back when we
  #     "pre-hashed" with sha512sum, and it is why plaintext was ever involved.
  #   _sh_pw — the plaintext, single-quote-escaped for the runcmd chpasswd
  #     BINARY line (also the only thing that can set ROOT's password; the
  #     chpasswd cloud-config key is deliberately NOT used: its `list` dialect
  #     is removed in new cloud-init, its `users` dialect is unknown to old
  #     ones, and specifying both is a hard error — "list and user commands
  #     not supported". The binary has no such versioning problems.)
  _gp="$(env_guest_password "$vm")"
  _pw_hash="$(openssl passwd -6 "$_gp")"
  _sh_pw="${_gp//\'/\'\\\'\'}"

  # ---- write_files accumulator ----------------------------------------------
  # Files the guest needs are shipped as cloud-init write_files entries with
  # base64 content, NOT as `printf '...\n...'` lines inside runcmd. The printf
  # form nested a shell script inside a YAML scalar inside a shell heredoc:
  # three escaping layers over one string, impossible to review, and it is where
  # the desktop installer kept breaking. base64 has no escaping layer at all.
  # write_files also runs in cloud-init's INIT stage, so the files are on disk
  # before any runcmd needs them.
  write_files_lines=""
  # add_write_file PATH MODE CMD [ARGS...] — append one entry, content taken
  # from CMD's stdout. Command substitution rather than a pipe on purpose: a
  # function on the right of a pipe runs in a subshell and its assignment to
  # write_files_lines would be discarded.
  add_write_file() {
    _wf_p="$1"; _wf_m="$2"; shift 2
    _wf_b="$("$@" | base64 | tr -d '\n')"
    write_files_lines="$write_files_lines
  - path: $_wf_p
    permissions: '$_wf_m'
    encoding: b64
    content: $_wf_b"
  }

  # ---- Desktop environment (config <env>_DE) --------------------------------
  # Cloud-init installs the chosen DE + display manager + autologin so the env
  # boots into a usable desktop. Works for BOTH Ubuntu (apt) and Arch (pacman) —
  # cloud-init abstracts the package manager; package NAMES differ per distro.
  # "none" keeps the env CLI-only. The actual installer comes from
  # lib/de-install.sh so that environments/guest-doctor.sh can drop the very
  # same script into a guest that cloud-init never provisioned.
  de_pkg_lines="  - qemu-guest-agent"
  # FIRST runcmd item: (re)set the guest + root passwords with the chpasswd
  # BINARY. users[].passwd above already carries the hash; this line is the
  # belt-and-braces (and the only root path) — it runs on every cloud-init
  # version because it is just a shell command, not a cloud-config dialect.
  de_runcmd_lines="  - |
    printf '%s\\n' '$GUEST_USER:$_sh_pw' 'root:$_sh_pw' | chpasswd
  - systemctl enable --now qemu-guest-agent || true"
  NEED_REBOOT=0
  _os="$(env_val "$vm" OS arch)"; _de="$(env_val "$vm" DE none)"

  # Admin group for the guest user, per distro (apt images ship sudo/adm but NOT
  # wheel; the Arch image ships wheel but NOT sudo). We deliberately do NOT put
  # this in the cloud-init user's `groups:` — cloud-init passes groups straight to
  # `useradd --groups` and a missing/finicky group there makes useradd ABORT, so
  # the guest user is never created (that was the "no operator, root only" bug).
  # Instead the user is created group-free (guaranteed) and added to the admin
  # group best-effort in runcmd afterwards. Privilege comes from `sudo:` anyway.
  case "$(os_family "$_os")" in
    apt) _grp_csv="sudo,adm" ;;
    *)   _grp_csv="wheel"
         # The Arch cloud image ships the `wheel` group but NOT the sudo package,
         # so cloud-init's `sudo: ALL=(ALL) NOPASSWD:ALL` above wrote a sudoers
         # drop-in for a binary that does not exist — the guest user ended up with
         # no way to escalate at all. Pull sudo in explicitly.
         de_pkg_lines="$de_pkg_lines
  - sudo" ;;
  esac
  de_runcmd_lines="$de_runcmd_lines
  - sh -c 'usermod -aG $_grp_csv $GUEST_USER 2>/dev/null || true'"

  # ---- Custom APT mirror / caching proxy (apt-family guests only) -----------
  # Emit a cloud-init top-level `apt:` block when APT_MIRROR/APT_PROXY are set.
  # cloud-init only honors this on apt distros, but we gate anyway to keep the
  # user-data clean for Arch. proxy is global (covers third-party repos too);
  # primary rewrites the base archive mirror.
  apt_cfg_lines=""
  if [ "$(os_family "$_os")" = "apt" ] && { [ -n "$APT_MIRROR" ] || [ -n "$APT_PROXY" ]; }; then
    apt_cfg_lines="apt:"
    if [ -n "$APT_PROXY" ]; then
      apt_cfg_lines="$apt_cfg_lines
  proxy: \"$APT_PROXY\""
    fi
    if [ -n "$APT_MIRROR" ]; then
      apt_cfg_lines="$apt_cfg_lines
  primary:
    - arches: [default]
      uri: \"$APT_MIRROR\""
    fi
    log "$vm: custom apt source (${APT_MIRROR:+mirror=$APT_MIRROR }${APT_PROXY:+proxy=$APT_PROXY})"
  fi
  if de_resolve "$_os" "$_de"; then
    # The installer and its retry unit are SHIPPED AS FILES (write_files, base64)
    # and generated by lib/de-install.sh — the same text environments/
    # guest-doctor.sh drops into a guest that cloud-init never touched.
    add_write_file /usr/local/sbin/appliance-install-de.sh 0755 \
      de_script "$_os" "$_de"
    add_write_file /etc/systemd/system/appliance-de.service 0644 de_unit

    # Run the installer DIRECTLY and synchronously here, then arm the unit for
    # later boots. It used to be `systemctl start --wait appliance-de.service`,
    # which is a trap: the unit carries Restart=on-failure, so on a guest whose
    # uplink is not up yet systemd keeps restarting it and --wait never returns
    # — cloud-final hangs for the entire boot, every boot. Calling the script is
    # bounded: it installs, or it returns non-zero and the unit retries later.
    de_runcmd_lines="$de_runcmd_lines
  - /usr/local/sbin/appliance-install-de.sh || true
  - systemctl daemon-reload || true
  - systemctl enable appliance-de.service || true"
    NEED_REBOOT=1

    # Autologin drop-in for whichever display manager this DE uses.
    _alp="$(de_autologin_path "$DE_DM")"
    if [ -n "$_alp" ]; then
      add_write_file "$_alp" 0644 de_autologin_content "$DE_DM" "$GUEST_USER" "$DE_SESSION"
    fi
    # Some display managers need more than a config file — Arch's lightdm will
    # not autologin a user who is not in the `autologin` group, and that group
    # does not exist until something creates it.
    _alx="$(de_autologin_extra_cmd "$DE_DM" "$GUEST_USER")"
    if [ -n "$_alx" ]; then
      de_runcmd_lines="$de_runcmd_lines
  - sh -c '$_alx'"
    fi
    log "$vm DE ($_os): $_de -> $DE_PKGS"
  fi

  # ---- Microsoft Intune enrollment prep (<env>_INTUNE=1, Ubuntu only) --------
  # Installs the Microsoft repo + intune-portal (+ Edge, pulled in). Enrollment
  # itself is INTERACTIVE: after boot, open "Microsoft Intune" in the desktop and
  # sign in with Entra (device compliance). We only pre-install the tooling.
  if [ "$(env_val "$vm" INTUNE 0)" = "1" ]; then
    if [ "$_os" = "ubuntu" ]; then
      require_pinned_fpr MS_GPG_FPR "Intune (Microsoft repo key)"
      de_runcmd_lines="$de_runcmd_lines
  - sh -c 'set -e; t=\$(mktemp); curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o \"\$t\"; f=\$(gpg --with-colons --import-options show-only --import \"\$t\" 2>/dev/null | grep \"^fpr\" | head -n1 | cut -f10 -d:); if [ \"\$f\" != \"$MS_GPG_FPR\" ]; then echo \"FATAL - Microsoft GPG key fingerprint mismatch (got \$f, expected $MS_GPG_FPR) -- aborting, Intune NOT installed.\" >&2; rm -f \"\$t\"; exit 1; fi; gpg --dearmor -o /usr/share/keyrings/microsoft.gpg < \"\$t\"; rm -f \"\$t\"'
  - sh -c '[ -s /usr/share/keyrings/microsoft.gpg ] && echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main\" > /etc/apt/sources.list.d/microsoft-prod.list && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y intune-portal && (systemctl enable microsoft-identity-broker 2>/dev/null || true)'"
      log "$vm: Intune prep queued (enroll interactively after boot)."
    else
      warn "$vm: INTUNE=1 ignored — Intune enrollment is Ubuntu-only (this env is $_os)."
    fi
  fi

  # ---- Microsoft apps: Teams + Outlook as Edge PWAs (<env>_MSAPPS=1) ---------
  # MS dropped the native Linux Teams; the community teams-for-linux wrapper works
  # but is an UNMANAGED client that Entra Conditional Access often blocks. Since
  # this is an Intune-enrolled device, we install Teams AND Outlook as PWAs inside
  # the managed Edge — that's the Conditional-Access-compliant path. (apt distros.)
  if [ "$(env_val "$vm" MSAPPS 0)" = "1" ] && [ "$(os_family "$_os")" = "apt" ]; then
    require_pinned_fpr MS_GPG_FPR "Edge/Outlook/Teams (Microsoft repo key)"
    de_runcmd_lines="$de_runcmd_lines
  - sh -c 'set -e; t=\$(mktemp); curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o \"\$t\"; f=\$(gpg --with-colons --import-options show-only --import \"\$t\" 2>/dev/null | grep \"^fpr\" | head -n1 | cut -f10 -d:); if [ \"\$f\" != \"$MS_GPG_FPR\" ]; then echo \"FATAL - Microsoft GPG key fingerprint mismatch (got \$f, expected $MS_GPG_FPR) -- aborting, Edge/Outlook/Teams NOT installed.\" >&2; rm -f \"\$t\"; exit 1; fi; gpg --dearmor -o /usr/share/keyrings/microsoft.gpg < \"\$t\"; rm -f \"\$t\"'
  - sh -c '[ -s /usr/share/keyrings/microsoft.gpg ] && echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main\" > /etc/apt/sources.list.d/microsoft-edge.list && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y microsoft-edge-stable'
  - sh -c '[ -s /usr/share/keyrings/microsoft.gpg ] && printf \"[Desktop Entry]\\nName=Outlook\\nExec=microsoft-edge-stable --app=https://outlook.office.com\\nType=Application\\nIcon=microsoft-edge\\nCategories=Office;Network;\\n\" > /usr/share/applications/outlook.desktop'
  - sh -c '[ -s /usr/share/keyrings/microsoft.gpg ] && printf \"[Desktop Entry]\\nName=Microsoft Teams\\nExec=microsoft-edge-stable --app=https://teams.microsoft.com\\nType=Application\\nIcon=microsoft-edge\\nCategories=Office;Network;\\n\" > /usr/share/applications/teams.desktop'"
    log "$vm: Outlook + Teams (Edge PWAs, Conditional-Access compliant) queued."
  fi

  # ---- Wazuh agent auto-enroll (<env>_WAZUH=1 + WAZUH_MANAGER) ----------------
  # Installs + registers the Wazuh agent pointing at WAZUH_MANAGER. Ubuntu via the
  # Wazuh apt repo; Arch via AUR (best-effort, needs base-devel + network).
  wm="${WAZUH_MANAGER:-}"
  if [ "$(env_val "$vm" WAZUH 0)" = "1" ]; then
    if [ -z "$wm" ]; then
      warn "$vm: WAZUH=1 but WAZUH_MANAGER is empty — skipping."
    elif [ "$(os_family "$_os")" = "apt" ]; then
      require_pinned_fpr WAZUH_GPG_FPR "Wazuh agent (Wazuh repo key)"
      de_runcmd_lines="$de_runcmd_lines
  - sh -c 'set -e; t=\$(mktemp); curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH -o \"\$t\"; f=\$(gpg --with-colons --import-options show-only --import \"\$t\" 2>/dev/null | grep \"^fpr\" | head -n1 | cut -f10 -d:); if [ \"\$f\" != \"$WAZUH_GPG_FPR\" ]; then echo \"FATAL - Wazuh GPG key fingerprint mismatch (got \$f, expected $WAZUH_GPG_FPR) -- aborting, Wazuh agent NOT installed.\" >&2; rm -f \"\$t\"; exit 1; fi; gpg --dearmor -o /usr/share/keyrings/wazuh.gpg < \"\$t\"; rm -f \"\$t\"'
  - sh -c '[ -s /usr/share/keyrings/wazuh.gpg ] && echo \"deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main\" > /etc/apt/sources.list.d/wazuh.list && apt-get update && WAZUH_MANAGER=\"$wm\" DEBIAN_FRONTEND=noninteractive apt-get install -y wazuh-agent && systemctl enable --now wazuh-agent'"
      log "$vm: Wazuh agent -> $wm (apt)."
    else   # arch (AUR, best-effort)
      de_runcmd_lines="$de_runcmd_lines
  - pacman -Sy --noconfirm --needed base-devel git
  - su - $GUEST_USER -c 'git clone https://aur.archlinux.org/wazuh-agent.git /tmp/wz && cd /tmp/wz && makepkg -si --noconfirm'
  - sed -i 's|<address>.*</address>|<address>$wm</address>|' /var/ossec/etc/ossec.conf
  - systemctl enable --now wazuh-agent"
      log "$vm: Wazuh agent -> $wm (AUR, best-effort)."
    fi
  fi

  # After a DE install, reboot once so the guest comes up in graphical.target
  # (gdm/lightdm is only ENABLED during cloud-init, not started that boot).
  # Condition on the install marker: if the DE could NOT be installed yet (no
  # internet at first boot), rebooting buys nothing — the enabled oneshot keeps
  # retrying every 30s and starts the display manager itself once it succeeds.
  power_state_lines=""
  [ "${NEED_REBOOT:-0}" = "1" ] && power_state_lines="power_state:
  mode: reboot
  condition: test -f /var/lib/appliance-de.done
  timeout: 30"

  umask 077
  cat > "$seed_dir/meta-data" <<EOF
instance-id: $vm
local-hostname: $host
EOF
  cat > "$seed_dir/user-data" <<EOF
#cloud-config
hostname: $host
users:
  - name: $GUEST_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
    passwd: '$_pw_hash'
# SSH password auth OFF (was on): nothing in the appliance logs into a guest over
# SSH — the host drives guests through the qemu-guest-agent, and the operator
# logs in at the SPICE console — so password SSH is pure attack surface for the
# (possibly shared, possibly weak) guest password. Console/viewer login is
# unaffected. Set <env>_SSH_PWAUTH=1 only if you deliberately need it.
ssh_pwauth: $( [ "$(env_val "$vm" SSH_PWAUTH 0)" = "1" ] && printf true || printf false )
# Files the guest needs, shipped base64 so no shell/YAML escaping layer can
# mangle them, and written in cloud-init's INIT stage — on disk before any
# runcmd below refers to them. Empty unless this env installs a desktop.
${write_files_lines:+write_files:$write_files_lines}
# Optional custom apt mirror/proxy (empty unless APT_MIRROR/APT_PROXY set).
$apt_cfg_lines
# Package install differs per distro but cloud-init abstracts it.
package_update: true
packages:
$de_pkg_lines
runcmd:
$de_runcmd_lines
$power_state_lines
# NOTE: no shared-folder / no cross-VM anything provisioned here (isolation).
EOF
  # Build the NoCloud seed ISO UNDER umask 077 and keep it 0600. The ISO holds
  # the guest+root password (SHA512 hash in user-data AND plaintext in the
  # chpasswd runcmd), so it must never be world-readable at rest — the appliance
  # provisions an unprivileged `kiosk` host user, and a 0644 seed let that user
  # `strings <env>-seed.iso` and lift the credential that guards every VM. qemu
  # here runs as root (no qemu.conf user override, no security driver), so 0600
  # root stays readable to the VM; where libvirt runs qemu unprivileged it
  # relabels attached disks itself (dynamic_ownership). Belt-and-braces: the seed
  # is also auto-ejected + shredded once cloud-init consumes it (isolate.sh).
  umask 077
  # Prefer cloud-localds; else xorriso's mkisofs (installed via virt-install on
  # Alpine); else genisoimage (Debian path). Volume label MUST be "cidata".
  seed_iso="$IMAGES_DIR/${vm}-seed.iso"
  if command -v cloud-localds >/dev/null 2>&1; then
    run cloud-localds "$seed_iso" "$seed_dir/user-data" "$seed_dir/meta-data"
  elif command -v mkisofs >/dev/null 2>&1; then
    run mkisofs -output "$seed_iso" -volid cidata -joliet -rock \
      "$seed_dir/user-data" "$seed_dir/meta-data"
  elif command -v xorriso >/dev/null 2>&1; then
    run xorriso -as mkisofs -o "$seed_iso" -V cidata -J -r \
      "$seed_dir/user-data" "$seed_dir/meta-data"
  elif command -v genisoimage >/dev/null 2>&1; then
    run genisoimage -output "$seed_iso" -volid cidata -joliet -rock \
      "$seed_dir/user-data" "$seed_dir/meta-data"
  else
    die "No ISO builder found (cloud-localds/mkisofs/xorriso/genisoimage)."
  fi
  # Shred the plaintext user-data now that it is baked into the ISO. (The ISO
  # itself still holds the password; environments/scrub-secrets.sh SCRUB_SEEDS=1
  # removes it once guests are provisioned.)
  shred -u "$seed_dir/user-data" 2>/dev/null || rm -f "$seed_dir/user-data"
  echo "$seed_iso"
}

# -----------------------------------------------------------------------------
# verify_image_sha256  FILE EXPECTED  — fail closed on missing/mismatched hash.
#   Deletes FILE on mismatch so a poisoned/corrupt image can never be reused
#   by a later idempotent run.
# -----------------------------------------------------------------------------
verify_image_sha256() {
  file="$1"; expected="$2"
  if [ -z "$expected" ]; then
    # OPTIONAL by default: no pin -> skip verification (just warn). Set the
    # matching *_IMG_SHA256 in config.env to turn on integrity checking for that
    # image, or REQUIRE_IMG_SHA256=1 to make a missing pin a hard error.
    if [ "${REQUIRE_IMG_SHA256:-0}" = "1" ]; then
      die "No SHA256 pinned for $(basename "$file") and REQUIRE_IMG_SHA256=1 — set its *_IMG_SHA256 or pin the vendor signing key via *_IMG_GPG_FPR in config.env (see config.env.example)."
    fi
    warn "$(basename "$file"): no SHA256 pinned — skipping integrity check (set *_IMG_SHA256 to enable)."
    return 0
  fi
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    rm -f "$file"
    die "SHA256 MISMATCH for $(basename "$file"): expected $expected, got $actual. Deleted the file — it may be corrupt, a stale mirror, or tampered. Re-verify the URL/hash before retrying."
  fi
  ok "$(basename "$file"): SHA256 verified."
}

# -----------------------------------------------------------------------------
# verify_image_vendor_sig  URL DEST OSKEY FPR — STRICT vendor-signature path.
#   Each vendor publishes a checksum file AND a detached signature for it in the
#   SAME directory as the image. That directory is derived from the URL, so the
#   dated directories from <OS>_IMG_DATE are respected automatically (the date
#   is part of the URL):
#     UBUNTU <dir>/SHA256SUMS      + SHA256SUMS.gpg
#     ARCH   <dir>/sha256sums.txt  + sha256sums.txt.sig
#     DEBIAN <dir>/SHA256SUMS      + SHA256SUMS.sign
#   The checksum file is what carries the trust: its signature is verified
#   against EXACTLY the pinned key FPR (via the VALIDSIG technique above — a
#   bare `gpg --verify` would accept a good signature from any known key), then
#   the image's sha256 is read out of the VERIFIED file and DEST is checked
#   against it. FAIL CLOSED at every step: a missing/unreadable/foreign
#   signature or a missing sums entry deletes DEST (fresh download OR cached
#   copy alike) and aborts.
#   The vendor key comes from IMG_GPG_KEYRING (an exported key file placed out
#   of band — preferred, no network trust at all) or, as a fallback, is fetched
#   BY FINGERPRINT with --recv-keys from IMG_GPG_KEYSERVER (safe only because
#   the fingerprint is the pin: a hostile keyserver cannot answer with a
#   different key).
# -----------------------------------------------------------------------------
verify_image_vendor_sig() {
  url="$1"; dest="$2"; oskey="$3"; fpr="$4"
  case "$oskey" in
    UBUNTU) sums_name="SHA256SUMS";     sig_name="SHA256SUMS.gpg" ;;
    ARCH)   sums_name="sha256sums.txt"; sig_name="sha256sums.txt.sig" ;;
    DEBIAN) sums_name="SHA256SUMS";     sig_name="SHA256SUMS.sign" ;;
    *)      die "verify_image_vendor_sig: unknown OS key '$oskey'." ;;
  esac
  dir="${url%/*}/"   # the image's own directory (dated dir when <OS>_IMG_DATE set)
  td="$(mktemp -d)"
  sums="$td/$sums_name"; sig="$td/$sig_name"; st="$td/gpg-status.txt"

  if ! wget -O "$sums" "${dir}${sums_name}" 2>/dev/null; then
    rm -rf "$td"; rm -f "$dest"
    die "$oskey: checksum file $sums_name missing next to the image (${dir}) — STRICT ${oskey}_IMG_GPG_FPR is pinned, so the image cannot be trusted. Deleted $(basename "$dest")."
  fi
  if ! wget -O "$sig" "${dir}${sig_name}" 2>/dev/null; then
    rm -rf "$td"; rm -f "$dest"
    die "$oskey: detached signature $sig_name missing next to the image (${dir}) — refusing to use an unsigned checksum file (STRICT ${oskey}_IMG_GPG_FPR). Deleted $(basename "$dest")."
  fi

  if [ -n "$IMG_GPG_KEYRING" ]; then
    rc=0
    gpg --batch --no-default-keyring --keyring "$IMG_GPG_KEYRING" \
        --status-fd 3 --verify "$sig" "$sums" 3>"$st" >/dev/null 2>>"$st" || rc=$?
  else
    if ! gpg --batch --keyserver "$IMG_GPG_KEYSERVER" --recv-keys "$fpr" >/dev/null 2>&1; then
      rm -rf "$td"; rm -f "$dest"
      die "$oskey: could not fetch vendor key $fpr from $IMG_GPG_KEYSERVER — set IMG_GPG_KEYRING to an exported key file instead (preferred: no network trust). Deleted $(basename "$dest")."
    fi
    rc=0
    gpg --batch --status-fd 3 --verify "$sig" "$sums" 3>"$st" >/dev/null 2>>"$st" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    sed 's/^/    /' "$st" >&2 || true
    rm -rf "$td"; rm -f "$dest"
    die "$oskey: vendor signature verification FAILED for $sums_name — refusing $(basename "$dest"). Deleted the image."
  fi
  if ! validsig_has_fpr "$st" "$fpr"; then
    sed 's/^/    /' "$st" >&2 || true
    rm -rf "$td"; rm -f "$dest"
    die "$oskey: $sums_name is signed, but not by the pinned key $fpr — refusing $(basename "$dest"). Deleted the image."
  fi
  ok "$oskey: $sums_name signature verified against pinned key $fpr."

  # The checksum file is now trustworthy: read the IMAGE's sha256 out of it —
  # never a hash that travelled outside the signature. sha256sum format is
  # "<hash>[ *]<filename>"; Ubuntu uses the '*' (binary) marker, Arch/Debian
  # plain names.
  want="$(basename "$url")"
  sha="$(awk -v f="$want" '{n=$2; sub(/^\*/,"",n); if (n==f) {print $1; exit}}' "$sums")"
  if [ -z "$sha" ]; then
    rm -rf "$td"; rm -f "$dest"
    die "$oskey: the VERIFIED $sums_name has no entry for $want — refusing $(basename "$dest") (fail closed). Deleted the image."
  fi
  rm -rf "$td"
  verify_image_sha256 "$dest" "$sha"
}

# -----------------------------------------------------------------------------
# fetch  URL DEST SHA256 OSKEY — download once (idempotent cache), then verify
#   integrity EVERY time — fresh download or cache hit alike (fail closed).
#   Verification precedence (see the config block at the top):
#     1. a non-empty SHA256 pin WINS — the signature path is skipped entirely
#        (it pins WHICH build, the stronger statement);
#     2. else a pinned <OSKEY>_IMG_GPG_FPR selects the STRICT vendor-signature
#        path (verify_image_vendor_sig);
#     3. else unverified (warning; hard error under REQUIRE_IMG_SHA256=1, which
#        a gpg pin therefore satisfies).
#   The fpr tri-state is resolved BEFORE the precedence decision so an
#   empty-but-set pin dies even when a SHA256 pin is present — blanking a pin
#   must never be a quiet downgrade.
# -----------------------------------------------------------------------------
fetch() {
  url="$1"; dest="$2"; expected_sha256="$3"; oskey="${4:-}"
  fpr=""
  [ -z "$oskey" ] || fpr="$(img_gpg_fpr "$oskey")"
  if [ -f "$dest" ]; then
    log "Cached: $(basename "$dest") — re-verifying integrity ..."
  else
    log "Downloading $(basename "$dest") ..."
    wget -O "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  if [ -n "$expected_sha256" ]; then
    [ -z "$fpr" ] || log "$(basename "$dest"): SHA256 pin set — it WINS; skipping the vendor-signature path."
    verify_image_sha256 "$dest" "$expected_sha256"
  elif [ -n "$fpr" ]; then
    verify_image_vendor_sig "$url" "$dest" "$oskey" "$fpr"
  else
    verify_image_sha256 "$dest" ""
  fi
}

# -----------------------------------------------------------------------------
# make_unattend_iso VMNAME HOSTNAME -> path to a small ISO holding
# autounattend.xml (+ the SPICE guest-tools installer). Windows Setup scans every
# attached optical/removable medium's root for autounattend.xml, so the volume
# label is not significant. The Windows counterpart to make_seed.
# -----------------------------------------------------------------------------
make_unattend_iso() {
  vm="$1"; host="$2"
  ud_dir="$CACHE_DIR/unattend-$vm"
  mkdir -p "$ud_dir"
  # autounattend.xml carries the guest password in plaintext (same sensitivity as
  # the Linux user-data). Lock the staging dir to root and write under umask 077;
  # the plaintext copy is shredded once the ISO is built (the ISO still holds it,
  # and environments/scrub-secrets.sh clears provisioning media afterwards).
  chmod 700 "$ud_dir" 2>/dev/null || true
  umask 077
  win_autounattend "$GUEST_USER" "$(env_guest_password "$vm")" "$host" "$WIN_LOCALE" "$WIN_TZ" \
    > "$ud_dir/autounattend.xml"
  # Bundle the SPICE guest-tools installer so the FirstLogonCommands can find it
  # on a known medium (virtio-win rides its own ISO). Best-effort.
  [ -f "$CACHE_DIR/spice-guest-tools.exe" ] \
    && cp "$CACHE_DIR/spice-guest-tools.exe" "$ud_dir/spice-guest-tools.exe"
  # Keep umask 077 through the ISO build: autounattend.xml holds the guest
  # password in plaintext, so the resulting ISO must be 0600, not world-readable
  # (the kiosk user could otherwise `strings` it). qemu here runs as root; where
  # libvirt runs it unprivileged it relabels attached media itself.
  unattend_iso="$IMAGES_DIR/${vm}-unattend.iso"
  if command -v xorriso >/dev/null 2>&1; then
    run xorriso -as mkisofs -o "$unattend_iso" -V UNATTEND -J -r "$ud_dir"
  elif command -v genisoimage >/dev/null 2>&1; then
    run genisoimage -output "$unattend_iso" -volid UNATTEND -joliet -rock "$ud_dir"
  elif command -v mkisofs >/dev/null 2>&1; then
    run mkisofs -output "$unattend_iso" -volid UNATTEND -joliet -rock "$ud_dir"
  else
    die "No ISO builder found (xorriso/genisoimage/mkisofs) to build the Windows answer file."
  fi
  shred -u "$ud_dir/autounattend.xml" 2>/dev/null || rm -f "$ud_dir/autounattend.xml"
  echo "$unattend_iso"
}

# -----------------------------------------------------------------------------
# create_windows_vm NAME NET VCPU RAM DISKGB — the Windows 11 path.
#   Fresh empty disk + operator's Windows ISO + virtio-win + our autounattend
#   ISO, booted on a q35 + UEFI + vTPM profile (what Windows 11 requires — a
#   DIFFERENT machine/firmware than the SeaBIOS Linux guests). No --import: an
#   actual unattended Setup runs on first boot. None of the Linux resilience
#   (offline password/network pre-seed, cloud-init) applies to NTFS, so the
#   answer file has to get it right the first time — see lib/windows-unattend.sh.
# -----------------------------------------------------------------------------
create_windows_vm() {
  name="$1"; net="$2"; vcpu="$3"; ram="$4"; disk="$5"
  vmdisk="$IMAGES_DIR/${name}.qcow2"

  [ -n "$WINDOWS_ISO" ] && [ -f "$WINDOWS_ISO" ] || die "$name is ${name}_OS=windows but WINDOWS_ISO is unset or missing (got '${WINDOWS_ISO:-}'). Set WINDOWS_ISO=/path/to/Win11.iso in config.env — this repo cannot download or license Windows for you."

  _need_mb="$(win_min_disk_mb)"
  [ "$((disk * 1024))" -ge "$_need_mb" ] \
    || warn "$name: ${disk} GB disk is below the ~$((_need_mb/1024)) GB floor for Windows 11 — Setup may run out of space. Raise ${name}_DISK_GB in config.env."

  # virtio-win: qemu-guest-agent (isolate.sh talks to it) + display/net drivers.
  # Cached + integrity-checked exactly like the base cloud images.
  step "Windows support media"
  fetch "$VIRTIO_WIN_URL" "$IMAGES_DIR/virtio-win.iso" "$VIRTIO_WIN_SHA256"

  # SPICE guest tools (spice-vdagent -> virt-viewer --auto-resize). Best-effort:
  # a guest without it still installs, just at a fixed resolution until installed.
  if [ ! -f "$CACHE_DIR/spice-guest-tools.exe" ]; then
    if run wget -O "$CACHE_DIR/spice-guest-tools.exe.part" "$SPICE_GUEST_TOOLS_URL"; then
      mv "$CACHE_DIR/spice-guest-tools.exe.part" "$CACHE_DIR/spice-guest-tools.exe"
    else
      rm -f "$CACHE_DIR/spice-guest-tools.exe.part"
      warn "$name: could not fetch SPICE guest tools — desktop auto-resize will be unavailable until installed by hand."
    fi
  fi

  # vTPM needs the swtpm backend on the host; Win11 will not install without it.
  command -v swtpm >/dev/null 2>&1 \
    || die "$name: swtpm is not installed — Windows 11 needs a vTPM. Install it on the host (Alpine: apk add swtpm) and re-run."

  # UEFI firmware. Prefer an EXPLICIT OVMF loader path: Alpine's ovmf package
  # ships no libvirt firmware-descriptor JSON, so `--boot uefi` autoselect finds
  # nothing and fails. Locations differ per distro, so probe the known ones.
  _ovmf_code=""; _ovmf_vars=""
  for _c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
            /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
            /usr/share/ovmf/x64/OVMF_CODE.fd /usr/share/qemu/edk2-x86_64-code.fd; do
    [ -f "$_c" ] && { _ovmf_code="$_c"; break; }
  done
  for _v in /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd \
            /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
            /usr/share/ovmf/x64/OVMF_VARS.fd /usr/share/qemu/edk2-i386-vars.fd; do
    [ -f "$_v" ] && { _ovmf_vars="$_v"; break; }
  done
  if [ -n "$_ovmf_code" ] && [ -n "$_ovmf_vars" ]; then
    _win_boot="loader=$_ovmf_code,loader.readonly=yes,loader.type=pflash,nvram.template=$_ovmf_vars"
    log "$name: UEFI firmware $_ovmf_code (vars template $_ovmf_vars)"
  else
    _win_boot="uefi"   # let libvirt autoselect (works where firmware JSONs exist)
    warn "$name: no OVMF loader found in the usual paths — falling back to '--boot uefi' autoselect. If virt-install reports no UEFI firmware, install ovmf/edk2 on the host."
  fi

  log "Preparing empty disk for $name (${disk} GB, Windows 11) ..."
  run qemu-img create -f qcow2 "$vmdisk" "${disk}G"

  unattend_iso="$(make_unattend_iso "$name" "$name")"

  step "Windows 11 install for $name  (q35 + UEFI + vTPM, ${vcpu} vCPU, ${ram} MB, ${disk} GB)"
  # boot.order: the (empty) HDD is tried FIRST — it has no EFI entry yet, so UEFI
  # falls through to the install CD. After Setup writes the boot manager, the HDD
  # boots directly and the CD is never reached again, so the "press any key to
  # boot from CD" prompt can only appear on the very first boot.
  # NIC = e1000e and disk bus = sata: both inbox Windows drivers, so Setup needs
  # NO driver injection to see the disk or reach the network (virtio would).
  set -- \
    --name "$name" \
    --osinfo win11 \
    --machine q35 \
    --memory "$ram" \
    --vcpus "$vcpu" \
    --cpu host-passthrough \
    --boot "$_win_boot" \
    --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
    --disk path="$vmdisk",format=qcow2,bus=sata,boot.order=1 \
    --disk device=cdrom,path="$WINDOWS_ISO",boot.order=2 \
    --disk device=cdrom,path="$IMAGES_DIR/virtio-win.iso" \
    --disk device=cdrom,path="$unattend_iso" \
    --network network="$net",model=e1000e \
    --graphics spice \
    --video model.type=qxl,model.ram=65536,model.vram=65536,model.vgamem=65536,model.heads=1 \
    --channel spicevmc \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --noautoconsole \
    --wait 0

  run virt-install "$@" || die "$name: virt-install (Windows) failed — see the output above."
  run virsh autostart "$name"
  ok "$name: Windows 11 unattended install started. First boot runs Setup (~20-40 min: partition, copy, OOBE), then autologin as '$GUEST_USER'. If the very first boot shows 'Press any key to boot from CD', press one. Watch: virsh console $name."
  return 0
}

# -----------------------------------------------------------------------------
# create_vm  NAME VARIANT NET VCPU RAM DISKGB BASEIMG HOSTNAME
#   Copies base cloud image to a per-VM disk, resizes, attaches cloud-init seed,
#   imports with virt-install (no interactive install — image is prebuilt).
#   CPU host-passthrough. SPICE graphics (software render; no GPU passthrough).
#   Windows (OS=windows) diverges entirely -> create_windows_vm (installs from an
#   ISO; no cloud image, no cloud-init, q35+UEFI+vTPM instead of SeaBIOS).
# -----------------------------------------------------------------------------
create_vm() {
  name="$1"; variant="$2"; net="$3"; vcpu="$4"; ram="$5"; disk="$6"; base="$7"; host="$8"
  step "Environment: $name  (os=$(env_val "$name" OS arch), ${vcpu} vCPU, ${ram} MB, ${disk} GB)"

  if virsh dominfo "$name" >/dev/null 2>&1; then
    # RECREATE lets you actually rebuild a VM to pick up cloud-init changes.
    #   RECREATE=1        -> rebuild every VM
    #   RECREATE="office" -> rebuild just these (space-separated) envs
    # Otherwise create is idempotent (existing VMs are left untouched).
    case " ${RECREATE:-} " in
      *" 1 "*|*" all "*|*" $name "*)
        warn "$name: RECREATE -> destroying + undefining the existing VM ..."
        virsh destroy "$name" 2>/dev/null || true
        virsh undefine "$name" --nvram --remove-all-storage 2>/dev/null \
          || virsh undefine "$name" --remove-all-storage 2>/dev/null \
          || virsh undefine "$name" 2>/dev/null || true
        rm -f "$IMAGES_DIR/${name}.qcow2" "$IMAGES_DIR/${name}-seed.iso" \
              "$IMAGES_DIR/${name}-unattend.iso" 2>/dev/null || true
        ;;
      *)
        warn "VM $name already exists — skipping (idempotent). Set RECREATE=$name (or RECREATE=1) to rebuild."
        virsh autostart "$name" 2>/dev/null || true
        return
        ;;
    esac
  fi

  vmdisk="$IMAGES_DIR/${name}.qcow2"

  # Windows 11 is a wholly separate path (ISO install, q35+UEFI+vTPM, no cloud
  # image / cloud-init / offline pre-seed). Branch off after the shared RECREATE
  # handling above; everything below here is Linux cloud-image only.
  if [ "$(os_family "$(env_val "$name" OS arch)")" = "windows" ]; then
    create_windows_vm "$name" "$net" "$vcpu" "$ram" "$disk"
    return
  fi

  # Per-env user-keyed encryption (ANSSI): <env>_ENCRYPT_DISK=1 makes this VM's
  # disk a LUKS-encrypted qcow2, unlocked by <env>_DISK_PASS (a secret the user
  # sets). libvirt holds the secret to start the domain; scrub-secrets blanks
  # <env>_DISK_PASS from config afterward. EXPERIMENTAL.
  disk_opts="path=$vmdisk,format=qcow2,bus=virtio"
  ENC_INJECT=0
  if [ "$(env_val "$name" ENCRYPT_DISK 0)" = "1" ]; then
    dpass="$(env_val "$name" DISK_PASS)"
    [ -n "$dpass" ] && [ "$dpass" != "generate" ] || \
      die "$name: ${name}_DISK_PASS is empty — per-env disk encryption needs an explicit passphrase in config.env (secrets are never auto-generated)."
    log "Preparing ENCRYPTED disk for $name (LUKS, ${disk}G) ..."
    # Flatten base -> LUKS-encrypted qcow2 (no backing: luks+backing is unsupported).
    secpath="$IMAGES_DIR/.${name}.pass"; umask 077; printf '%s' "$dpass" > "$secpath"
    run qemu-img convert -O qcow2 -o "encrypt.format=luks,encrypt.key-secret=sec0" \
      --object "secret,id=sec0,file=$secpath" "$base" "$vmdisk"
    qemu-img resize --object "secret,id=sec0,file=$secpath" \
      "encrypt.key-secret=sec0" "$vmdisk" "${disk}G" 2>/dev/null || qemu-img resize "$vmdisk" "${disk}G" 2>/dev/null || true
    # Define a libvirt secret so the domain can unlock the disk at start.
    secuuid="$(printf '%s' "$name" | md5sum | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\).*/\1-\2-\3-\4-\5/')"
    sec_xml="$(mktemp)"
    cat > "$sec_xml" <<SX
<secret ephemeral='no' private='yes'>
  <uuid>$secuuid</uuid>
  <usage type='volume'><volume>$vmdisk</volume></usage>
</secret>
SX
    virsh secret-define "$sec_xml" >/dev/null 2>&1 || true
    virsh secret-set-value "$secuuid" --base64 "$(printf '%s' "$dpass" | base64)" >/dev/null 2>&1 || true
    rm -f "$sec_xml" "$secpath"
    # NOTE: do NOT put encryption.* on --disk — older virt-install rejects those
    # suboptions ("unknown --disk options: encryption.format ..."). Describe the
    # disk plainly and inject the <encryption> element into the domain XML below
    # (version-independent). ENC_INJECT drives that path.
    disk_opts="path=$vmdisk,format=qcow2,bus=virtio"
    ENC_INJECT=1
  else
    log "Preparing disk for $name (${disk}G) ..."
    run qemu-img create -f qcow2 -F qcow2 -b "$base" "$vmdisk"   # backing = base cloud img (thin)
    run qemu-img resize "$vmdisk" "${disk}G"
    # ---- Pre-seed the login, BEFORE the guest has ever booted ---------------
    # The password below is also handed to cloud-init (users[].passwd and a
    # chpasswd in runcmd). This third path exists because the first two share a
    # single point of failure: they only happen if cloud-init runs at all. When
    # it does not — a datasource it declined to read, a seed it never saw — the
    # operator gets a login prompt that no password opens, on all three
    # environments at once, with no way in and no way to find out why. Writing
    # the hash into the image now makes a working login independent of anything
    # that happens at boot. cloud-init finding the account already there is
    # harmless: it logs that useradd had nothing to do and applies the same
    # password on top.
    # Best-effort by design — an appliance without qemu-nbd still gets the two
    # cloud-init paths, so this can warn and move on but must never abort a build.
    if gd_supported; then
      _hash="$(openssl passwd -6 "$(env_guest_password "$name")")"
      # The trap is load-bearing: an interrupt between attach and detach leaves
      # /dev/nbdN holding the qcow2 open, and virt-install then fails on a disk
      # that looks perfectly fine on disk.
      trap 'gd_detach' EXIT INT TERM
      if gd_attach "$vmdisk" rw; then
        gd_set_password "$GD_MNT" "$GUEST_USER" "$_hash" 1 \
          && ok "$name: login pre-seeded for '$GUEST_USER' + root (works even if cloud-init does not run)." \
          || warn "$name: could not pre-seed the login — relying on cloud-init alone."
        # Seed DHCP networking too, for the same reason: cloud-init's network
        # module has been seen to leave the NIC up-but-unconfigured (link-local
        # only), which strands apt and the desktop install. This brings the
        # interface up via systemd-networkd with no help from cloud-init.
        gd_seed_network "$GD_MNT" "$(os_family "$(env_val "$name" OS arch)")" \
          && ok "$name: DHCP networking seeded into the disk (comes up even if cloud-init's network stage does not)." \
          || warn "$name: could not seed networking — relying on cloud-init."
        gd_detach
      else
        warn "$name: could not open the new disk to pre-seed the login — relying on cloud-init alone."
      fi
      trap - EXIT INT TERM
    else
      warn "$name: qemu-nbd/nbd unavailable — login depends on cloud-init succeeding. If it does not, see src/environments.sh guest-doctor."
    fi
  fi

  seed_iso="$(make_seed "$name" "$host")"

  log "virt-install $name (vcpu=$vcpu ram=${ram}MB net=$net) ..."
  # --import: boot the prebuilt image; no OS installer runs. cloud-init in the
  # image consumes the NoCloud seed on first boot => unattended provisioning.
  # The org.qemu.guest_agent.0 channel lets the host talk to qemu-guest-agent in
  # the guest — needed for isolate.sh's in-guest verification.
  #
  # --machine pc: pin the i440fx machine type, which boots on SeaBIOS. Without
  # it, recent libvirt defaults these guests to q35 + UEFI (OVMF), and OVMF
  # probes for Intel TDX on every boot — that is the "virt/tdx: TDX not supported
  # by the host platform" banner operators saw, and the firmware phase is what
  # made the boot feel very long. SeaBIOS has no such probe and comes up fast.
  # It also presents the seed as a plain IDE CD-ROM (the canonical NoCloud
  # layout), rather than an OVMF SATA CD-ROM, so cloud-init's datasource
  # detection is on its most well-trodden path. The cloud images (Ubuntu/Arch/
  # Debian) all boot on BIOS, so nothing is lost.
  # TODO(GPU-passthrough): VFIO needs q35 (PCIe). To go that route, drop
  #   --machine pc, switch to q35, and replace --graphics spice/--video qxl with
  #   --graphics none --hostdev <PCI-of-GPU>,address.type=pci — then expect the
  #   OVMF firmware back (and pin an edk2 build without the TDX probe if the slow
  #   boot returns). Only ONE VM can own the single physical GPU at a time.
  # --video qxl with 64 MB each of ram/vram/vgamem (the default is ~16 MB, which
  # caps the guest around 1600p and forces the viewer to SCALE a too-small
  # framebuffer — the pixelated, not-quite-fullscreen look). 64 MB covers 4K.
  # Crisp, tile-filling output ALSO needs spice-vdagent inside the guest so
  # virt-viewer's --auto-resize can set the guest resolution to the window size;
  # lib/de-install.sh installs it with the desktop.
  set -- \
    --name "$name" \
    --os-variant "$variant" \
    --machine pc \
    --memory "$ram" \
    --vcpus "$vcpu" \
    --cpu host-passthrough \
    --import \
    --disk "$disk_opts" \
    --disk path="$seed_iso",device=cdrom \
    --network network="$net",model=virtio \
    --graphics spice \
    --video model.type=qxl,model.ram=65536,model.vram=65536,model.vgamem=65536,model.heads=1 \
    --channel spicevmc \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --noautoconsole \
    --wait 0

  if [ "$ENC_INJECT" = "1" ]; then
    # Encrypted: generate the domain XML WITHOUT starting (--print-xml), inject
    # the <encryption> element into the main disk (identified by its source path),
    # then define + start. Works regardless of virt-install's --disk suboption
    # support. Booting a LUKS qcow2 without this element would fail to read root.
    log "$name: defining with injected LUKS <encryption> (secret $secuuid) ..."
    domxml="$(virt-install "$@" --print-xml)" \
      || die "$name: virt-install --print-xml failed."
    printf '%s\n' "$domxml" | awk -v f="$vmdisk" -v uu="$secuuid" '
      { print }
      index($0, "source") && index($0, "file=") && index($0, f) {
        print "      <encryption format='"'"'luks'"'"'>"
        print "        <secret type='"'"'passphrase'"'"' uuid='"'"'" uu "'"'"'/>"
        print "      </encryption>"
      }' | virsh define /dev/stdin >/dev/null \
        || die "$name: virsh define (encrypted) failed."
    virsh start "$name" || die "$name: virsh start (encrypted) failed — check the disk passphrase/secret."
  else
    run virt-install "$@"
  fi

  run virsh autostart "$name"
  ok "$name created + autostart enabled."
}

# -----------------------------------------------------------------------------
# Download only the base image(s) actually needed by the enabled envs' OSes.
# -----------------------------------------------------------------------------
step "Base images (download + integrity check)"
need_ubuntu=0; need_arch=0; need_debian=0
for pair in $(for_each_enabled_env | awk '{print $1}'); do
  case "$(env_val "$pair" OS arch)" in ubuntu) need_ubuntu=1;; arch) need_arch=1;; debian) need_debian=1;; esac
done
[ "$need_ubuntu" = 1 ] && fetch "$UBUNTU_IMG_URL" "$IMAGES_DIR/base-ubuntu.img"   "$UBUNTU_IMG_SHA256" UBUNTU
[ "$need_arch"   = 1 ] && fetch "$ARCH_IMG_URL"   "$IMAGES_DIR/base-arch.qcow2"   "$ARCH_IMG_SHA256" ARCH
[ "$need_debian" = 1 ] && fetch "$DEBIAN_IMG_URL" "$IMAGES_DIR/base-debian.qcow2" "$DEBIAN_IMG_SHA256" DEBIAN

# ENTRA/INTUNE constraint: any env with INTUNE=1 MUST be Ubuntu (Intune Linux
# enrollment is Ubuntu-only). Enforce so the office/desktop stays Ubuntu.
for pair in $(for_each_enabled_env | awk '{print $1}'); do
  _pos="$(env_val "$pair" OS arch)"
  if [ "$(env_val "$pair" INTUNE 0)" = "1" ] && [ "$_pos" != "ubuntu" ] && [ "$_pos" != "windows" ]; then
    die "$pair has INTUNE=1 but OS=$_pos — Intune/Entra enrollment is supported on Windows (native MDM/Entra join) or Ubuntu (intune-portal) only. Set ${pair}_OS=windows or ubuntu."
  fi
done

# -----------------------------------------------------------------------------
# Build every ENABLED environment. OS -> base image + os-variant. Resource sizes
# and the isolated network come from config (written by 01 / ensured above).
# -----------------------------------------------------------------------------
for_each_enabled_env | while read -r env idx; do
  os="$(env_val "$env" OS arch)"
  base="$(os_base "$os")" || { warn "Unsupported OS '$os' for $env (use ubuntu|arch|debian); skipping."; continue; }
  create_vm "$env" "$(os_variant "$os")" "$(env_net "$env")" \
            "$(env_val "$env" VCPU 1)" "$(env_val "$env" RAM_MB 1024)" \
            "$(env_val "$env" DISK_GB 10)" "$base" "$env"
done

ok "All enabled VMs created."
virsh list --all
cat <<EOF

MANUAL: first boot of each VM runs cloud-init, which INSTALLS the desktop
environment over the network (ubuntu-desktop/gnome etc. — several minutes on
first boot, then one automatic reboot into the DE). It's slow the first time by
design; watch progress with:
    virsh console <name>     (Ctrl+] to exit)
    # in-guest: tail -f /var/log/de-install.log   (DE package install log)

If a guest ends up with no desktop, or no password works at its login prompt,
do NOT guess — shut it down and ask it directly (works with no password and no
guest agent, because it reads the disk from here):
    virsh shutdown <name>
    ./src/environments.sh guest-doctor <name>

Next: ./src/environments.sh isolate   (or ./setup.sh 2)
EOF
;;
isolate)
# =============================================================================
# environments/isolate.sh
# -----------------------------------------------------------------------------
# The critical isolation layer. Defense-in-depth:
#   1. Per-VM isolated libvirt networks (separate bridge + /24 each). Ensured
#      here authoritatively (03 also ensures them; this repairs/confirms).
#   2. Explicit host nftables rules that DROP all traffic BETWEEN the VM bridges
#      /subnets, while ALLOWING each VM outbound to the internet via NAT.
#   3. Verification test: from each VM, ping the other two (must FAIL) and ping
#      the internet (must SUCCEED). Prints pass/fail.
#
# Layering: libvirt's own per-network firewalling + our explicit cross-bridge
# DROP means even if one layer is misconfigured, the other still blocks peers.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
require_root
load_config
require_cmds nft virsh

# -----------------------------------------------------------------------------
# 1. Auto-detect WAN uplink interface (the one the host actually reaches the
#    internet through).
#
# `ip route get` and NOT `ip route show default | first`: a host with more than
# one default route — e.g. Wi-Fi AND Ethernet both up — lists them in an order
# the first-match parse cannot reason about, so it would pick whichever happens
# to be listed first. That bit an operator who ran this on Wi-Fi (pinning
# wlan0), then plugged in Ethernet: every guest's NAT masquerade and forward
# accept stayed scoped to the now-wrong wlan0, so guests got a DHCP lease and
# could reach their gateway but nothing beyond it (100% loss to the internet).
# `ip route get 1.1.1.1` consults metrics and returns the dev the kernel would
# ACTUALLY use, which is the only correct answer when several defaults exist.
if [ "${WAN_IFACE:-auto}" = "auto" ]; then
  WAN_IFACE="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)"
  # Fallback for a host with a default route but no route to 1.1.1.1 specifically.
  [ -n "$WAN_IFACE" ] || WAN_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  [ -n "$WAN_IFACE" ] || die "Could not auto-detect WAN interface; set WAN_IFACE in config.env."
fi
set_kv WAN_IFACE "$WAN_IFACE"
log "WAN uplink: $WAN_IFACE"

# -----------------------------------------------------------------------------
# 2. Ensure the three isolated networks exist (idempotent, same as 03).
# -----------------------------------------------------------------------------
ensure_net() {
  name="$1"; bridge="$2"; subnet="$3"
  if ! virsh net-info "$name" >/dev/null 2>&1; then
    tmpxml="$(mktemp)"
    cat > "$tmpxml" <<EOF
<network>
  <name>$name</name>
  <forward mode='nat'/>
  <bridge name='$bridge' stp='on' delay='0'/>
  <ip address='${subnet}.1' netmask='255.255.255.0'>
    <dhcp><range start='${subnet}.2' end='${subnet}.254'/></dhcp>
  </ip>
</network>
EOF
    run virsh net-define "$tmpxml"; rm -f "$tmpxml"
  fi
  virsh net-start "$name" >/dev/null 2>&1 || true
  virsh net-autostart "$name" >/dev/null 2>&1 || true
}
# Ensure an isolated network per ENABLED env, and collect "env:idx" tokens.
step "Isolated networks"
LIST=""
for_each_enabled_env | while read -r env idx; do
  ensure_net "$(env_net "$env")" "$(env_bridge "$env" "$idx")" "$(env_subnet "$env" "$idx")"
done
LIST="$(for_each_enabled_env | awk '{print $1":"$2}')"
# ALL envs by fixed position (enabled or not). Inter-env DROP rules are built over
# this superset so an env that was created then DISABLED — its libvirt net + VM
# keep running — stays fenced off instead of silently gaining reachability to the
# others. Egress/NAT below stay ENABLED-only. DROP rules for a subnet whose bridge
# doesn't exist are harmless (they simply never match).
LIST_ALL="$(_i=0; for _e in $ENVS; do _i=$((_i+1)); printf '%s:%s\n' "$_e" "$_i"; done)"

# Guard (fail closed): a non-empty EGRESS_ALLOW only has effect in whitelist mode.
# If an env sets an allow-list but leaves MODE=all, emit_egress ignores it and
# emits an unconditional WAN accept — egress is wide open while the config looks
# locked down. Refuse rather than mislead.
for a in $LIST; do
  ea="${a%:*}"
  if [ "$(env_val "$ea" EGRESS_MODE all)" != "whitelist" ] && [ -n "$(env_val "$ea" EGRESS_ALLOW)" ]; then
    die "$ea: EGRESS_ALLOW is set but EGRESS_MODE is not 'whitelist' — the allow-list would be IGNORED and egress left wide open. Set ${ea}_EGRESS_MODE=whitelist (or clear ${ea}_EGRESS_ALLOW)."
  fi
done

# emit_egress <subnet-net> <gw-ip> <mode> <allow-list> -> nft forward lines.
emit_egress() {
  net="$1"; gw="$2"; mode="$3"; allow="$4"; idx="$5"
  if [ "$mode" = "whitelist" ]; then
    printf '    ip saddr %s ip daddr %s udp dport 53 accept\n' "$net" "$gw"
    printf '    ip saddr %s ip daddr %s tcp dport 53 accept\n' "$net" "$gw"
    if [ -n "$allow" ]; then
      set_str="$(echo "$allow" | tr ' ' ',')"
      printf '    ip saddr %s oifname "%s" ip daddr { %s } accept\n' "$net" "$WAN_IFACE" "$set_str"
    fi
    # If this env is VPN-locked (environments/vpn.sh brings up wg<idx>), let its
    # tunnel-bound traffic through here too. Base chains on the same hook are ALL
    # evaluated and an accept in appliance_vpn is not terminal for appliance_isol,
    # so without this the whitelist drop below would kill packets vpn.sh accepted,
    # leaving a VPN+whitelist env with zero connectivity. Harmless when no wg<idx>
    # exists (the oifname simply never matches).
    printf '    ip saddr %s oifname "wg%s" accept\n' "$net" "$idx"
    printf '    ip saddr %s counter drop\n' "$net"
  else
    printf '    ip saddr %s oifname "%s" accept\n' "$net" "$WAN_IFACE"
    # Same VPN carve-out as the whitelist branch: with the forward chain now at
    # `policy drop` (below), a mode=all env that is ALSO VPN-locked would have
    # its tunnel-bound traffic dropped — the WAN accept above never matches an
    # oifname of wg<idx>. Accept it explicitly. Harmless when no wg<idx> exists.
    printf '    ip saddr %s oifname "wg%s" accept\n' "$net" "$idx"
  fi
}

# Build nftables rule fragments.
DROP_RULES=""; BRIDGE_DROP=""; EGRESS_RULES=""; NAT_RULES=""
# Inter-env DROP + bridge DROP over ALL defined env positions (every ordered pair).
for a in $LIST_ALL; do
  ea="${a%:*}"; ia="${a#*:}"; na="$(env_subnet "$ea" "$ia").0/24"; ba="$(env_bridge "$ea" "$ia")"
  for b in $LIST_ALL; do
    [ "$a" = "$b" ] && continue
    eb="${b%:*}"; ib="${b#*:}"; nb="$(env_subnet "$eb" "$ib").0/24"; bb="$(env_bridge "$eb" "$ib")"
    DROP_RULES="$DROP_RULES
    ip saddr $na ip daddr $nb counter drop"
    BRIDGE_DROP="$BRIDGE_DROP
    iifname \"$ba\" oifname \"$bb\" counter drop"
  done
done
# Per-env egress policy + NAT for ENABLED envs only (a disabled env gets no internet).
for a in $LIST; do
  ea="${a%:*}"; ia="${a#*:}"; na="$(env_subnet "$ea" "$ia").0/24"; gwa="$(env_subnet "$ea" "$ia").1"
  EGRESS_RULES="$EGRESS_RULES
$(emit_egress "$na" "$gwa" "$(env_val "$ea" EGRESS_MODE all)" "$(env_val "$ea" EGRESS_ALLOW)" "$ia")"
  NAT_RULES="$NAT_RULES
    ip saddr $na oifname \"$WAN_IFACE\" masquerade"
done
log "Isolation for enabled envs: $(echo "$LIST" | tr '\n' ' ')"

# -----------------------------------------------------------------------------
# 3. nftables: block ALL inter-env traffic; permit each env's outbound per policy.
# -----------------------------------------------------------------------------
step "Firewall isolation (nftables)"
log "Applying nftables inter-env DROP + NAT rules ..."
NFT_FILE="/etc/nftables.d/appliance-isolation.nft"
mkdir -p /etc/nftables.d

cat > "$NFT_FILE" <<EOF
#!/usr/sbin/nft -f
# ===== Appliance VM isolation (generated by environments/isolate.sh) =====
table inet appliance_isol
delete table inet appliance_isol

table inet appliance_isol {
  chain forward {
    # FAIL CLOSED: policy drop, not accept. Previously this chain relied ENTIRELY
    # on its explicit per-pair drop rules matching, and fell through to `policy
    # accept` for anything they missed — so a single un-generated pair (subnet /
    # bridge drift, a new env type, a partial reload) or a host lacking the
    # assumed base `inet filter` drop-policy (the Debian/systemd path defines no
    # such table) left those environments able to route to each other. With
    # `policy drop`, inter-VM forwarding is IMPOSSIBLE unless a rule below
    # explicitly permits it, and the only permits below are egress to the WAN /
    # the env's own VPN tunnel and established return traffic — never VM->VM.
    # Isolation no longer depends on a base table this repo does not write.
    type filter hook forward priority -1; policy drop;
    # HARD BLOCK: every enabled-env subnet -> every OTHER env subnet (both dirs).
    # These come FIRST, ahead of the conntrack fast-path below: a cross-env flow
    # that was established before these rules existed (or during a window where
    # they were flushed) still has a live conntrack entry, and an
    # "established,related accept" placed above the drops would keep waving that
    # flow through for the lifetime of the entry. Isolation must not depend on
    # when the rules happened to be loaded.
$DROP_RULES

    # Belt-and-suspenders: same block by bridge interface name. Interface-based,
    # so it is family-agnostic and covers IPv6 between bridges as well.
$BRIDGE_DROP

    # Everything that survived the cross-env drops: let return traffic through.
    ct state established,related accept

    # Per-env egress policy ("all" = full internet, "whitelist" = DNS + listed).
$EGRESS_RULES
  }

  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
$NAT_RULES
  }
}
EOF

# Ensure the main nftables config includes our drop-in (Alpine + Debian).
MAIN_NFT="/etc/nftables.nft"
[ -f "$MAIN_NFT" ] || MAIN_NFT="/etc/nftables.conf"
if [ -f "$MAIN_NFT" ] && ! grep -q "appliance-isolation.nft" "$MAIN_NFT"; then
  echo "include \"$NFT_FILE\"" >> "$MAIN_NFT"
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-appliance-forward.conf
nft -f "$NFT_FILE"
ok "nftables isolation applied."

# -----------------------------------------------------------------------------
# 3a. FUNCTIONAL guest connectivity through the host's OWN base firewall.
#
# The nftables service loads Alpine's default /etc/nftables.nft at boot, and that
# ships `table inet filter` with BOTH the input AND forward chains at
# `policy drop`. A drop there is FINAL regardless of what appliance_isol (above)
# or libvirt accept elsewhere on the same hook — nftables evaluates every base
# chain on a hook and any drop wins. So without the rules below:
#   * a guest's DHCP request to its gateway (the host's dnsmasq, udp/67) is
#     dropped -> no lease -> the NIC comes up with an IPv6 link-local address
#     only, no IPv4, no default route ("network is unreachable"); and
#   * even with an address, the guest's NAT egress is dropped by the forward
#     policy.
# harden.sh adds equivalent input accepts, but ONLY when HARDEN_INPUT=1. These
# are FUNCTIONAL, not hardening — the environments need them in BOTH modes — so
# they live here. Isolation is unaffected: appliance_isol runs at priority -1,
# ahead of this filter chain, and its cross-subnet drops are terminal, so
# inter-env traffic never reaches these accepts.
#
# Verified end to end (dnsmasq + a guest on a veth, real nftables): with the base
# `policy drop` in place the guest gets NO lease; with these rules it does, and
# the inter-env drops stay effective.
GUESTNET_NFT="/etc/nftables.d/appliance-guest-net.nft"
cat > "$GUESTNET_NFT" <<EOF
#!/usr/sbin/nft -f
# Generated by environments/isolate.sh. Appended to the base 'inet filter'
# chains, which the main nftables.nft defines before it includes this directory.
# DHCP + DNS from the guests to their per-env gateway (the host), and their
# outbound NAT egress via the WAN uplink. Return traffic to the guests too.
add rule inet filter input iifname "virbr*" udp dport 67 accept
add rule inet filter input iifname "virbr*" udp dport 53 accept
add rule inet filter input iifname "virbr*" tcp dport 53 accept
add rule inet filter forward iifname "virbr*" oifname "$WAN_IFACE" accept
add rule inet filter forward oifname "virbr*" ct state established,related accept
EOF
# Load at every boot. Alpine's default main config already does
# `include "/etc/nftables.d/*.nft"`; only add an explicit include when the main
# config neither globs this directory nor already names the file, so it is never
# loaded twice (which would just stack identical accepts).
if [ -f "$MAIN_NFT" ] \
   && ! grep -q '/etc/nftables.d/\*\.nft' "$MAIN_NFT" \
   && ! grep -q "appliance-guest-net.nft" "$MAIN_NFT"; then
  echo "include \"$GUESTNET_NFT\"" >> "$MAIN_NFT"
fi
# Apply now — the base 'inet filter' table exists in the running ruleset. Non-
# fatal on purpose: a host whose base ruleset lacks that table simply won't get
# these until its own config provides them, and that must not abort the
# isolation load (which is the security-critical part).
if nft -f "$GUESTNET_NFT" 2>/dev/null; then
  ok "Guest DHCP/DNS + egress permitted through the host base firewall."
else
  warn "Could not apply $GUESTNET_NFT now (no base 'inet filter' table?). If guests get no IP, this is why — see the comment in isolate.sh."
fi

# -----------------------------------------------------------------------------
# 3b. HOST-SIDE assertion (no guest agent needed): every ordered env pair has a
#     live DROP rule.
# -----------------------------------------------------------------------------
# Verification tallies. FAILED is what decides this script's exit status: an
# isolation breach must be a non-zero exit, not just a yellow line that scrolls
# past in an unattended first-boot log.
FAILED=0; SKIPPED=0; PASSED=0

log "Host-side check: verifying inter-env DROP rules are live ..."
live="$(nft list table inet appliance_isol 2>/dev/null || true)"; miss=0; npair=0
for a in $LIST; do
  ea="${a%:*}"; ia="${a#*:}"; na="$(env_subnet "$ea" "$ia").0/24"
  for b in $LIST; do
    [ "$a" = "$b" ] && continue
    eb="${b%:*}"; ib="${b#*:}"; nb="$(env_subnet "$eb" "$ib").0/24"; npair=$((npair+1))
    if echo "$live" | grep -q "ip saddr $na ip daddr $nb .*drop"; then
      ok   "DROP present: $ea -> $eb"
    else
      warn "DROP MISSING: $ea -> $eb"; miss=$((miss+1))
    fi
  done
done
if [ "$miss" -eq 0 ]; then
  ok "All $npair inter-env DROP rules present."
else
  warn "$miss/$npair DROP rule(s) missing — isolation NOT complete!"
  FAILED=$((FAILED+miss))
fi

# -----------------------------------------------------------------------------
# 4. Verification test.
#    For each VM: run commands inside the guest via the qemu-guest-agent
#    (installed by cloud-init in 03). Ping the other two VM gateways/hosts
#    (must FAIL) and ping the internet (must SUCCEED). Prints PASS/FAIL.
#
#    We ping each peer's GATEWAY .1 AND a would-be peer host .2 — both must fail.
#    If the guest agent isn't up yet, we note SKIPPED (re-run after boot).
# -----------------------------------------------------------------------------
guest_exec() {
  # guest_exec <domain> <command...> -> prints exit code of in-guest command.
  dom="$1"; shift
  out="$(virsh -q qemu-agent-command "$dom" \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$*\"],\"capture-output\":true}}" \
    2>/dev/null)" || { echo "AGENT_DOWN"; return; }
  pid="$(echo "$out" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')"
  [ -n "$pid" ] || { echo "AGENT_DOWN"; return; }
  # POLL for completion instead of sleeping a fixed 3s and reading once. A ping
  # that is dropped (exactly the case these checks care about) waits out its
  # full timeout, and a loaded guest is slower still — a single early read
  # returns "exited":false, no exitcode, and the check degrades to SKIPPED,
  # which reads as "couldn't test" when isolation may in fact be broken.
  _i=0
  while [ "$_i" -lt "${GUEST_EXEC_TIMEOUT:-20}" ]; do
    st="$(virsh -q qemu-agent-command "$dom" \
      "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>/dev/null)"
    case "$st" in
      *'"exited":true'*|*'"exited": true'*)
        echo "$st" | sed -n 's/.*"exitcode":[[:space:]]*\([0-9]*\).*/\1/p'
        return ;;
    esac
    sleep 1; _i=$((_i+1))
  done
  echo "TIMEOUT"
}

# report expected(0=success,1=fail) actual label
verify() {
  dom="$1"; expect="$2"; label="$3"; cmd="$4"
  rc="$(guest_exec "$dom" "$cmd")"
  if [ "$rc" = "AGENT_DOWN" ] || [ -z "$rc" ]; then
    warn "[$dom] $label -> SKIPPED (guest agent not ready)"
    SKIPPED=$((SKIPPED+1)); return
  fi
  if [ "$rc" = "TIMEOUT" ]; then
    warn "[$dom] $label -> SKIPPED (in-guest command did not finish in ${GUEST_EXEC_TIMEOUT:-20}s)"
    SKIPPED=$((SKIPPED+1)); return
  fi
  # normalize: rc 0 = command succeeded (reachable); non-zero = unreachable.
  reached=$([ "$rc" = "0" ] && echo yes || echo no)
  if [ "$expect" = "reach" ] && [ "$reached" = "yes" ]; then
    ok   "[$dom] $label -> PASS (reachable, expected)"; PASSED=$((PASSED+1))
  elif [ "$expect" = "block" ] && [ "$reached" = "no" ]; then
    ok   "[$dom] $label -> PASS (blocked, expected)"; PASSED=$((PASSED+1))
  else
    warn "[$dom] $label -> FAIL (reached=$reached, expected=$expect)"
    FAILED=$((FAILED+1))
  fi
}

step "Verification"
PING='ping -c1 -W2'
log "Running isolation verification (guests must be booted with guest agent) ..."

# For each enabled env: must NOT reach any OTHER enabled env's gateway; MUST
# reach the internet (unless its egress is whitelisted without 1.1.1.1).
for a in $LIST; do
  ea="${a%:*}"
  for b in $LIST; do
    [ "$a" = "$b" ] && continue
    eb="${b%:*}"; ib="${b#*:}"; gw="$(env_subnet "$eb" "$ib").1"
    verify "$ea" block "cannot reach $eb net" "$PING $gw"
  done
  if [ "$(env_val "$ea" EGRESS_MODE all)" = "all" ]; then
    verify "$ea" reach "reaches internet (1.1.1.1)" "$PING 1.1.1.1"
  fi
done

cat <<EOF

Isolation verification complete: $PASSED passed, $FAILED failed, $SKIPPED skipped.
If SKIPPED: wait for guests to finish cloud-init, then re-run:  ./src/environments.sh isolate
EOF

# -----------------------------------------------------------------------------
# 4a. Eject the cloud-init provisioning seed once the guest has consumed it.
#
# The NoCloud seed ISO carries the guest+root password — a SHA512 hash in
# user-data AND, in the chpasswd runcmd, the password in PLAINTEXT. Left
# attached, it is a CD-ROM any process inside the guest can mount (`mount
# /dev/sr0`) and read. Because the SAME secret provisions every environment,
# that copy is the lateral-movement seed for a cross-domain pivot: a compromised
# office VM lifts the administration VM's credential straight off its own seed.
#
# cloud-init only needs the seed on FIRST boot; create.sh ALSO pre-seeded the
# login + networking OFFLINE into the disk (gd_set_password / gd_seed_network),
# so the guest stays fully functional once the seed is gone. So the moment we
# can confirm cloud-init has FINISHED, detach the CD-ROM from both the live
# domain and its persistent config, then shred the ISO on the host.
#
# Honest about "not yet": a guest whose agent is down, or whose cloud-init is
# still running, KEEPS its seed and is retried on the next isolate.sh run — it
# never loses the login to a premature eject. This is orthogonal to the
# isolation verdict above, so it touches neither FAILED nor the exit status.
# Default ON; set EJECT_SEEDS=0 to keep seeds attached (e.g. debugging a boot).
# -----------------------------------------------------------------------------
if [ "${EJECT_SEEDS:-1}" = "1" ]; then
  step "Eject provisioning seeds"
  for a in $LIST; do
    ea="${a%:*}"
    # Windows guests use an autounattend ISO, not a NoCloud seed. Both are named
    # *-seed.iso / *-unattend.iso by create.sh; match only the cloud-init seed.
    seed="$(virsh domblklist "$ea" 2>/dev/null | awk '$NF ~ /-seed\.iso$/ {print $NF; exit}')"
    if [ -z "$seed" ]; then
      log "[$ea] no cloud-init seed attached (already ejected) — nothing to do."
      continue
    fi
    # Only eject once cloud-init has actually finished, so a guest whose first
    # boot is still installing the desktop keeps the seed it is still reading.
    # guest_exec returns the in-guest exit code; grep matches the terminal states.
    fin="$(guest_exec "$ea" "cloud-init status 2>/dev/null | grep -Eq 'status: (done|error|disabled)'")"
    case "$fin" in
      0) : ;;                                  # cloud-init finished -> safe to eject
      AGENT_DOWN|TIMEOUT|"")
        warn "[$ea] guest agent not ready — seed kept; re-run isolate.sh once first boot finishes."
        continue ;;
      *)
        warn "[$ea] cloud-init still running — seed kept; re-run isolate.sh once it finishes."
        continue ;;
    esac
    # Detach from the LIVE domain AND the PERSISTENT config. The cdrom's target
    # dev is auto-assigned by libvirt, so resolve it by source path (domblklist
    # prints "Target Source"; the source is the last column).
    tgt="$(virsh domblklist "$ea" 2>/dev/null | awk -v f="$seed" '$NF==f {print $1; exit}')"
    if [ -n "$tgt" ]; then
      virsh detach-disk "$ea" "$tgt" --live --config 2>/dev/null \
        || virsh detach-disk "$ea" "$tgt" --config 2>/dev/null \
        || { warn "[$ea] could not detach seed cdrom '$tgt' — leaving $seed in place."; continue; }
    fi
    # Remove the ISO from the host ONLY once nothing in the persistent (inactive)
    # config still points at it — a dangling <source> would wedge the next start.
    # shred: the file still holds the plaintext password.
    if [ -z "$(virsh domblklist "$ea" --inactive 2>/dev/null | awk -v f="$seed" '$NF==f {print $1; exit}')" ]; then
      shred -u "$seed" 2>/dev/null || rm -f "$seed" 2>/dev/null || true
      ok "[$ea] cloud-init seed ejected + shredded ($seed)."
      audit_event seed-eject env="$ea" seed="$(basename "$seed")"
    else
      warn "[$ea] seed still referenced by the persistent config — not removing $seed."
    fi
  done
fi

# -----------------------------------------------------------------------------
# 5. Continuous assurance. Everything above is a snapshot: it proves isolation
#    at this instant and exits, after which a flushed ruleset or a redefined
#    libvirt network would go unnoticed until someone re-ran this script.
#    Publish the verdict where anything can read it and install the recurring
#    check, so the machine can still answer "am I isolated?" a week from now.
#
#    Additive on purpose: neither call may influence this script's exit status,
#    which reports THIS run's verification result and nothing else. It is placed
#    before the exit block so the status file is populated even on a failed run
#    (a broken machine especially needs a readable verdict).
# -----------------------------------------------------------------------------
WATCH="$HERE/host.sh"
if [ -x "$WATCH" ]; then
  "$WATCH" isolation-watch --install-timer || warn "Could not install the recurring isolation check — run src/host.sh isolation-watch --install-timer by hand."
  "$WATCH" isolation-watch --once || true
else
  warn "src/host.sh not found — isolation will only ever be verified when this script is run by hand."
fi

# Exit status reflects the SECURITY result, so a caller (setup.sh, a first-boot
# service, CI) can tell a verified-isolated appliance from a broken one without
# scraping the log. Skips are not failures — they mean "not yet testable".
if [ "$FAILED" -gt 0 ]; then
  die "$FAILED isolation check(s) FAILED — the environments are NOT properly isolated. Investigate before using this machine (see README)."
fi
if [ "$SKIPPED" -gt 0 ]; then
  warn "$SKIPPED check(s) skipped — isolation is NOT fully verified yet. Re-run once the guests have finished booting."
fi
ok "Isolation verified."
;;
vpn)
# =============================================================================
# environments/vpn.sh   (ANSSI #8 — dedicated, non-bypassable per-env VPN)
# -----------------------------------------------------------------------------
# For every ENABLED environment with <env>_VPN=1, bring up a HOST-side WireGuard
# tunnel and force that environment's egress THROUGH it — enforced on the host,
# so the guest cannot disable or bypass it ("non débrayable", ANSSI).
#
# How the non-bypass is enforced (all on the host, out of the guest's control):
#   * a WireGuard interface wg<idx> per env (keys/endpoint from config.env);
#   * policy routing: packets from the env's /24 use a table whose default route
#     is the wg interface;
#   * nftables (table inet appliance_vpn, evaluated BEFORE appliance_isol):
#       - DROP env-subnet -> WAN uplink   (can't leak around the tunnel)
#       - ACCEPT env-subnet -> wg<idx>, and masquerade out wg<idx>.
#
# OPT-IN + EXPERIMENTAL: needs a real WireGuard peer (endpoint + keys) and
# on-hardware testing. Default off (no <env>_VPN=1) -> this script is a no-op.
# Run AFTER environments/isolate.sh (it layers on top of the isolation table).
#
# Required per-env config.env vars when <env>_VPN=1:
#   <env>_VPN_PRIVKEY   host private key for this env's tunnel   (SENSITIVE)
#   <env>_VPN_ADDRESS   wg interface address, e.g. 10.9.<idx>.2/32
#   <env>_VPN_PUBKEY    peer (gateway) public key
#   <env>_VPN_ENDPOINT  peer host:port
#   <env>_VPN_ALLOWED   allowed IPs (default 0.0.0.0/0 = full tunnel)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
require_root
load_config
require_cmds wg wg-quick ip nft

# Detect WAN (same logic as 05) so we can DROP env->WAN for VPN'd envs.
if [ "${WAN_IFACE:-auto}" = "auto" ]; then
  WAN_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
fi
[ -n "${WAN_IFACE:-}" ] || die "WAN_IFACE unknown; run ./src/environments.sh isolate first (or set WAN_IFACE in config.env)."

mkdir -p /etc/wireguard

any=0
VPN_FWD=""; VPN_NAT=""
for_each_enabled_env | while read -r env idx; do
  [ "$(env_val "$env" VPN 0)" = "1" ] || continue
  any=1
  subnet="$(env_subnet "$env" "$idx")"      # e.g. 10.10.2
  net="${subnet}.0/24"
  wgif="wg${idx}"                           # <=15 chars, unique per env
  priv="$(env_val "$env" VPN_PRIVKEY)"
  addr="$(env_val "$env" VPN_ADDRESS)"
  pub="$(env_val "$env" VPN_PUBKEY)"
  ep="$(env_val "$env" VPN_ENDPOINT)"
  allowed="$(env_val "$env" VPN_ALLOWED 0.0.0.0/0)"
  [ -n "$priv" ] && [ -n "$addr" ] && [ -n "$pub" ] && [ -n "$ep" ] || {
    warn "$env: VPN=1 but missing PRIVKEY/ADDRESS/PUBKEY/ENDPOINT — skipping."; continue; }

  log "$env: WireGuard $wgif -> $ep (egress locked to tunnel) ..."
  # Table=off: we do the policy routing ourselves (per-env table).
  umask 077
  cat > "/etc/wireguard/${wgif}.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $addr
Table = off

[Peer]
PublicKey = $pub
Endpoint = $ep
AllowedIPs = $allowed
PersistentKeepalive = 25
EOF
  umask 022

  wg-quick down "$wgif" 2>/dev/null || true
  wg-quick up "$wgif" || { warn "$env: wg-quick up failed (endpoint/keys?)."; continue; }

  # Policy routing: env subnet -> table (100+idx) whose default is the tunnel.
  rt=$((100 + idx))
  ip route replace default dev "$wgif" table "$rt"
  ip rule del from "$net" lookup "$rt" 2>/dev/null || true
  ip rule add from "$net" lookup "$rt" priority $((1000 + idx))

  VPN_FWD="$VPN_FWD
    ip saddr $net oifname \"$WAN_IFACE\" counter drop
    ip saddr $net oifname \"$wgif\" accept"
  VPN_NAT="$VPN_NAT
    ip saddr $net oifname \"$wgif\" masquerade"
  ok "$env: egress now forced through $wgif; direct WAN dropped."
done

# NOTE: the per-env loop above runs in a pipe subshell, so VPN_FWD/VPN_NAT built
# there don't survive. Rebuild them in the main shell to write the nft table.
VPN_FWD=""; VPN_NAT=""; any=0
for pair in $(for_each_enabled_env | awk '{print $1":"$2}'); do
  env="${pair%:*}"; idx="${pair#*:}"
  [ "$(env_val "$env" VPN 0)" = "1" ] || continue
  [ -f "/etc/wireguard/wg${idx}.conf" ] || continue
  any=1
  net="$(env_subnet "$env" "$idx").0/24"; wgif="wg${idx}"
  VPN_FWD="$VPN_FWD
    ip saddr $net oifname \"$WAN_IFACE\" counter drop
    ip saddr $net oifname \"$wgif\" accept"
  VPN_NAT="$VPN_NAT
    ip saddr $net oifname \"$wgif\" masquerade"
done

if [ "$any" = "0" ]; then
  log "No env has VPN=1 — nothing to do (per-env VPN disabled)."
  exit 0
fi

# nftables table evaluated BEFORE appliance_isol (lower priority number) so the
# 'drop env->WAN' is terminal and the guest cannot leak around the tunnel.
NFT_VPN="/etc/nftables.d/appliance-vpn.nft"
mkdir -p /etc/nftables.d
cat > "$NFT_VPN" <<EOF
#!/usr/sbin/nft -f
table inet appliance_vpn
delete table inet appliance_vpn
table inet appliance_vpn {
  chain forward {
    type filter hook forward priority -2; policy accept;
    ct state established,related accept
$VPN_FWD
  }
  chain postrouting {
    type nat hook postrouting priority 90; policy accept;
$VPN_NAT
  }
}
EOF
MAIN_NFT="/etc/nftables.nft"; [ -f "$MAIN_NFT" ] || MAIN_NFT="/etc/nftables.conf"
if [ -f "$MAIN_NFT" ] && ! grep -q "appliance-vpn.nft" "$MAIN_NFT"; then
  echo "include \"$NFT_VPN\"" >> "$MAIN_NFT"
fi
nft -f "$NFT_VPN"
ok "Per-env VPN egress-lock applied (ANSSI #8: dedicated, non-bypassable tunnel)."

# -----------------------------------------------------------------------------
# Persistence. The nft egress-lock persists on its own (it is included from the
# main nftables config), and that half is fail-closed — but the wg interfaces and
# the policy-routing rules live only in the running kernel. After a reboot a
# VPN'd env would come up with the lock still dropping its WAN traffic and no
# tunnel to use instead: permanently offline, with nothing on screen saying why.
# Install a boot service that re-establishes the tunnels + rules.
# -----------------------------------------------------------------------------
# Both writers below go through a temp file + mv. The boot service re-runs THIS
# script, so a plain `cat >` would truncate the very file the running shell is
# still reading; an atomic rename leaves that inode alone.
install_boot_service() {
  _tmp="$(mktemp)"
  mkdir -p /etc/init.d /etc/systemd/system 2>/dev/null || true
  if command -v rc-update >/dev/null 2>&1; then          # OpenRC (Alpine)
    cat > "$_tmp" <<EOF
#!/sbin/openrc-run
description="Per-env WireGuard tunnels + policy routing (appliance)"
depend() { need net; after firewall nftables; }
start() {
    ebegin "Restoring per-env VPN tunnels"
    $HERE/vpn.sh >/var/log/appliance-vpn.log 2>&1
    eend \$?
}
EOF
    chmod +x "$_tmp"; mv "$_tmp" /etc/init.d/appliance-vpn
    rc-update add appliance-vpn default 2>/dev/null || true
    ok "Boot service installed (OpenRC: appliance-vpn) — tunnels come back after a reboot."
  elif command -v systemctl >/dev/null 2>&1; then        # systemd (Debian path)
    cat > "$_tmp" <<EOF
[Unit]
Description=Per-env WireGuard tunnels + policy routing (appliance)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HERE/vpn.sh

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$_tmp"; mv "$_tmp" /etc/systemd/system/appliance-vpn.service
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable appliance-vpn.service 2>/dev/null || true
    ok "Boot service installed (systemd: appliance-vpn) — tunnels come back after a reboot."
  else
    rm -f "$_tmp"
    warn "No OpenRC/systemd found — re-run environments/vpn.sh by hand after every reboot, or the VPN'd envs stay offline (the egress lock is fail-closed)."
  fi
}
install_boot_service

cat <<EOF

Verify from inside a VPN'd VM: its public IP should be the VPN endpoint's, and
direct WAN must be blocked (only the tunnel works).
EOF
;;
diode)
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
# shellcheck source=lib.sh
export LIBVIRT_DEFAULT_URI=qemu:///system
# Root: the diode reads config.env (mode 0600 — it names the domains authorized
# to exchange), writes the audit record, and drives the guest agents. The
# acceptance prompt therefore runs on the socle's root console (tty2 /
# setup.sh step 11) — a support surface outside every user domain, which
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
;;
guest-doctor)
# =============================================================================
# environments/guest-doctor.sh — inspect and repair a guest WITHOUT its help
# -----------------------------------------------------------------------------
# Every other guest tool in this repo talks to the qemu-guest-agent, and the
# agent is installed by cloud-init. So when cloud-init does not provision a
# guest, the operator gets a login prompt no password opens, no desktop, and no
# tool that can tell them why — set-guest-password.sh can only answer "is the VM
# running with the guest agent up?". This script goes in through the host: it
# attaches the guest's qcow2 with qemu-nbd and reads (or fixes) the filesystem
# directly. It needs nothing from inside the guest.
#
# The VM must be SHUT OFF. Touching a disk a live qemu also has open corrupts
# it, so every mode here refuses to run against a running domain.
#
# Usage:
#   guest-doctor.sh                          report on every enabled env
#   guest-doctor.sh office                   report on one env
#   guest-doctor.sh --password office        reset that env's password (prompts)
#   guest-doctor.sh --password all 's3cret'  reset every env's password
#   guest-doctor.sh --install-de office      install the desktop installer
#                                            offline, so it runs on next boot
#   NO_ROOT=1 guest-doctor.sh --password ... change only $GUEST_USER, not root
#
# Deliberately NOT `set -e`: this is a diagnostic. A grep that finds nothing is
# an ANSWER here, not a reason to abort before printing the rest of the report.
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
# shellcheck source=lib.sh
# shellcheck source=lib.sh
require_root
load_config
require_cmds virsh qemu-img openssl
export LIBVIRT_DEFAULT_URI=qemu:///system

MODE="report"
NEW_PW=""
targets=""

while [ $# -gt 0 ]; do
  case "$1" in
    --password|--passwd) MODE="password"; shift
      targets="${1:-all}"; [ $# -gt 0 ] && shift
      NEW_PW="${1:-}"; [ $# -gt 0 ] && shift ;;
    --install-de) MODE="install-de"; shift
      targets="${1:-all}"; [ $# -gt 0 ] && shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *)  targets="$targets $1"; shift ;;
  esac
done

[ -n "$(printf '%s' "$targets" | tr -d ' ')" ] || targets="all"
if [ "$(printf '%s' "$targets" | tr -d ' ')" = "all" ]; then
  targets="$(for_each_enabled_env | awk '{print $1}')"
fi

GUEST_USER="${GUEST_USER:-operator}"

# -----------------------------------------------------------------------------
# shadow_state FILE USER — say what a /etc/shadow entry actually permits.
# The distinction that matters: an account with '!' or '*' as its hash cannot be
# logged into at ALL, which is exactly what a guest looks like when cloud-init
# never set a password — and from the console it is indistinguishable from
# "wrong password".
# -----------------------------------------------------------------------------
shadow_state() {
  _sf="$1"; _u="$2"
  [ -f "$_sf" ] || { printf 'no /etc/shadow'; return; }
  _h="$(awk -F: -v u="$_u" '$1==u {print $2; exit}' "$_sf")"
  case "$_h" in
    "")        printf 'NO SUCH USER' ;;
    '!'*|'*'*) printf 'LOCKED (no password can log in)' ;;
    '$6$'*)    printf 'set (sha512-crypt)' ;;
    '$y$'*|'$7$'*) printf 'set (yescrypt)' ;;
    '$'*)      printf 'set (%s)' "$(printf '%s' "$_h" | cut -d'$' -f2)" ;;
    *)         printf 'unrecognised hash' ;;
  esac
}

# -----------------------------------------------------------------------------
# report_one ENV — everything we can learn about this guest, host side first
# (which does not need the disk) then from inside the image.
# -----------------------------------------------------------------------------
report_one() {
  e="$1"
  _os="$(env_val "$e" OS arch)"; _de="$(env_val "$e" DE none)"
  printf '\n\033[1m=== %s (os=%s de=%s) ===\033[0m\n' "$e" "$_os" "$_de"

  if ! virsh dominfo "$e" >/dev/null 2>&1; then
    printf '  domain           : DOES NOT EXIST (run src/environments.sh create)\n'
    return
  fi
  _state="$(virsh domstate "$e" 2>/dev/null | head -n1)"
  printf '  domain           : %s\n' "$_state"

  _disk="$(gd_domain_disk "$e")"
  _seed="$(gd_domain_seed "$e")"
  printf '  disk             : %s\n' "${_disk:-NONE}"
  if [ -n "$_disk" ] && [ -f "$_disk" ]; then
    printf '  disk virtual size: %s\n' "$(qemu-img info "$_disk" 2>/dev/null | awk -F'[:(]' '/virtual size/ {print $2; exit}' | sed 's/^ *//')"
  fi

  # The cloud-init seed. If this CD-ROM is not attached, cloud-init had nothing
  # to read and NOTHING in the seed was ever applied — no user, no password, no
  # desktop. That is the single most useful line in this report.
  if [ -z "$_seed" ]; then
    printf '  cloud-init seed  : \033[1;31mNOT ATTACHED to the domain\033[0m\n'
  elif [ ! -f "$_seed" ]; then
    printf '  cloud-init seed  : \033[1;31mattached as %s but the FILE IS GONE\033[0m\n' "$_seed"
    printf '                     (scrub-secrets.sh SCRUB_SEEDS=1 deletes it; the guest\n'
    printf '                      cannot be re-provisioned without rebuilding the seed)\n'
  else
    printf '  cloud-init seed  : %s (%s bytes)\n' "$_seed" "$(wc -c < "$_seed" 2>/dev/null | tr -d ' ')"
  fi

  if [ -z "$_disk" ] || [ ! -f "$_disk" ]; then
    printf '  guest filesystem : cannot inspect (no disk file)\n'; return
  fi
  if ! gd_require_off "$e"; then
    printf '  guest filesystem : \033[1;33mNOT INSPECTED — the VM is running.\033[0m\n'
    printf '                     Shut it down and re-run:  virsh shutdown %s\n' "$e"
    return
  fi
  if [ "$(env_val "$e" ENCRYPT_DISK 0)" = "1" ]; then
    printf '  guest filesystem : not inspected (LUKS-encrypted disk)\n'; return
  fi

  trap 'gd_detach' EXIT INT TERM
  if ! gd_attach "$_disk" ro; then
    printf '  guest filesystem : could not attach the disk (see warning above)\n'
    trap - EXIT INT TERM; return
  fi

  printf '  --- inside the guest ---\n'
  printf '  hostname         : %s\n' "$(cat "$GD_MNT/etc/hostname" 2>/dev/null || echo '(none)')"

  # cloud-init's own verdict. /var/lib/cloud survives a shutdown (unlike the
  # /run copies), and the instance directory is named after the meta-data
  # instance-id we generated — so seeing our env name here proves cloud-init
  # actually read OUR seed rather than some other datasource.
  if [ -d "$GD_MNT/var/lib/cloud/instances" ]; then
    printf '  cloud-init ran as: %s\n' "$(ls "$GD_MNT/var/lib/cloud/instances" 2>/dev/null | tr '\n' ' ')"
  else
    printf '  cloud-init ran as: \033[1;31mNEVER RAN (no /var/lib/cloud/instances)\033[0m\n'
  fi
  if [ -f "$GD_MNT/var/lib/cloud/instance/datasource" ]; then
    printf '  datasource       : %s\n' "$(cat "$GD_MNT/var/lib/cloud/instance/datasource" 2>/dev/null)"
  else
    printf '  datasource       : \033[1;31mnone recorded — the seed was not consumed\033[0m\n'
  fi

  printf '  %-16s : %s\n' "user '$GUEST_USER'" "$(shadow_state "$GD_MNT/etc/shadow" "$GUEST_USER")"
  printf '  %-16s : %s\n' "user 'root'" "$(shadow_state "$GD_MNT/etc/shadow" root)"
  # The Ubuntu cloud image's built-in account, reported because operators reach
  # for it by reflex: our seed replaces `users:` wholesale, so it is NOT created.
  if [ "$_os" = "ubuntu" ]; then
    printf '  %-16s : %s\n' "user 'ubuntu'" "$(shadow_state "$GD_MNT/etc/shadow" ubuntu)"
  fi

  # Desktop
  if [ "$_de" != "none" ]; then
    if [ -f "$GD_MNT/var/lib/appliance-de.done" ]; then
      printf '  desktop install  : DONE\n'
    elif [ -f "$GD_MNT/var/lib/appliance-de.nospace" ]; then
      printf '  desktop install  : \033[1;31mABORTED — guest disk too small\033[0m\n'
    elif [ -f "$GD_MNT/usr/local/sbin/appliance-install-de.sh" ]; then
      printf '  desktop install  : \033[1;33marmed but not completed\033[0m\n'
    else
      printf '  desktop install  : \033[1;31mnever armed (the installer is not in the image)\033[0m\n'
    fi
    _tgt="$(readlink "$GD_MNT/etc/systemd/system/default.target" 2>/dev/null | sed 's|.*/||')"
    printf '  default target   : %s\n' "${_tgt:-(distro default, normally multi-user)}"
    if [ -f "$GD_MNT/var/log/de-install.log" ]; then
      printf '  --- de-install.log (last 12) ---\n'
      tail -n 12 "$GD_MNT/var/log/de-install.log" 2>/dev/null | sed 's/^/    /'
    fi
  fi

  # Root-filesystem usage, because "no space" is the failure this whole class of
  # bug hides behind.
  printf '  root fs usage    : %s\n' "$(df -Pm "$GD_MNT" 2>/dev/null | awk 'NR==2 {printf "%sMB used, %sMB free (%s)", $3, $4, $5}')"

  if [ -f "$GD_MNT/var/log/cloud-init.log" ]; then
    _err="$(grep -iE 'traceback|CRITICAL|ERROR' "$GD_MNT/var/log/cloud-init.log" 2>/dev/null | tail -n 8)"
    if [ -n "$_err" ]; then
      printf '  --- cloud-init.log errors (last 8) ---\n'
      printf '%s\n' "$_err" | sed 's/^/    /'
    else
      printf '  cloud-init errors: none logged\n'
    fi
  else
    printf '  cloud-init log   : \033[1;31mabsent — cloud-init never started\033[0m\n'
  fi

  gd_detach
  trap - EXIT INT TERM
}

# -----------------------------------------------------------------------------
# set_password_one ENV — write the password straight into the guest's
# /etc/shadow, creating the account if cloud-init never did. This is the path
# that works when nothing inside the guest works.
# -----------------------------------------------------------------------------
set_password_one() {
  e="$1"; hash="$2"
  virsh dominfo "$e" >/dev/null 2>&1 || { warn "$e: no such domain — skipping."; return 1; }
  gd_require_off "$e" || {
    warn "$e: the VM is RUNNING. Shut it down first:  virsh shutdown $e   (then re-run)"
    return 1
  }
  if [ "$(env_val "$e" ENCRYPT_DISK 0)" = "1" ]; then
    warn "$e: LUKS-encrypted disk — offline password reset is not supported."; return 1
  fi
  _disk="$(gd_domain_disk "$e")"
  [ -n "$_disk" ] && [ -f "$_disk" ] || { warn "$e: no disk file found."; return 1; }

  trap 'gd_detach' EXIT INT TERM
  gd_attach "$_disk" rw || { trap - EXIT INT TERM; return 1; }

  _with_root=1; [ "${NO_ROOT:-0}" = "1" ] && _with_root=0
  if ! awk -F: -v u="$GUEST_USER" '$1==u {found=1} END {exit !found}' "$GD_MNT/etc/passwd"; then
    warn "$e: '$GUEST_USER' does not exist in this guest — creating it."
  fi
  if ! gd_set_password "$GD_MNT" "$GUEST_USER" "$hash" "$_with_root"; then
    gd_detach; trap - EXIT INT TERM; return 1
  fi

  gd_detach
  trap - EXIT INT TERM
  if [ "$_with_root" = "1" ]; then
    ok "$e: password set for '$GUEST_USER' and root."
  else
    ok "$e: password set for '$GUEST_USER'."
  fi
  return 0
}

# -----------------------------------------------------------------------------
# install_de_one ENV — put the desktop installer into a guest that never got it,
# so the desktop appears on the next boot without rebuilding the VM.
# -----------------------------------------------------------------------------
install_de_one() {
  e="$1"
  _os="$(env_val "$e" OS arch)"; _de="$(env_val "$e" DE none)"
  [ "$_de" != "none" ] || { warn "$e: ${e}_DE=none — nothing to install."; return 0; }
  de_resolve "$_os" "$_de" || { warn "$e: no desktop resolved."; return 1; }
  gd_require_off "$e" || { warn "$e: the VM is RUNNING. Shut it down first."; return 1; }
  _disk="$(gd_domain_disk "$e")"
  [ -n "$_disk" ] && [ -f "$_disk" ] || { warn "$e: no disk file found."; return 1; }

  trap 'gd_detach' EXIT INT TERM
  gd_attach "$_disk" rw || { trap - EXIT INT TERM; return 1; }

  mkdir -p "$GD_MNT/usr/local/sbin" "$GD_MNT/etc/systemd/system/multi-user.target.wants"
  de_script "$_os" "$_de" > "$GD_MNT/usr/local/sbin/appliance-install-de.sh"
  chmod 755 "$GD_MNT/usr/local/sbin/appliance-install-de.sh"
  de_unit > "$GD_MNT/etc/systemd/system/appliance-de.service"
  chmod 644 "$GD_MNT/etc/systemd/system/appliance-de.service"
  # Enable it the way systemctl would have: WantedBy=multi-user.target is just
  # this symlink, and we cannot run systemctl inside an offline image.
  ln -sf /etc/systemd/system/appliance-de.service \
     "$GD_MNT/etc/systemd/system/multi-user.target.wants/appliance-de.service"

  _alp="$(de_autologin_path "$DE_DM")"
  if [ -n "$_alp" ]; then
    mkdir -p "$GD_MNT$(dirname "$_alp")"
    de_autologin_content "$DE_DM" "$GUEST_USER" "$DE_SESSION" > "$GD_MNT$_alp"
  fi
  # lightdm autologin also needs the user in the `autologin` group (Arch enforces
  # this); do it offline since we cannot run gpasswd in the image.
  if [ "$DE_DM" = "lightdm" ]; then
    _grf="$GD_MNT/etc/group"
    awk -F: '$1=="autologin" {found=1} END {exit !found}' "$_grf" \
      || printf 'autologin:x:%s:\n' "$(awk -F: '$3>=900 && $3<1000 {m=($3>m)?$3:m} END {print (m?m+1:990)}' "$_grf")" >> "$_grf"
    gd_group_add "$_grf" autologin "$GUEST_USER"
  fi

  rm -f "$GD_MNT/var/lib/appliance-de.nospace" 2>/dev/null
  gd_detach
  trap - EXIT INT TERM
  ok "$e: desktop installer armed ($_de via $DE_DM). It runs on the next boot; watch /var/log/de-install.log in the guest."
  return 0
}

# -----------------------------------------------------------------------------
# Dispatch.
# -----------------------------------------------------------------------------
gd_supported || warn "qemu-nbd/nbd module unavailable — offline inspection will not work on this host."

rc=0
case "$MODE" in
  report)
    for e in $targets; do report_one "$e"; done
    cat <<'EOF'

How to read this
  "cloud-init ran as: NEVER RAN" or "datasource: none recorded"
      -> the seed was never consumed. Nothing in it applied: no user, no
         password, no desktop. Check the "cloud-init seed" line above.
  "user 'operator': LOCKED" or "NO SUCH USER"
      -> no password can log in. Fix it without rebuilding:
             ./src/environments.sh guest-doctor --password <env>
  "desktop install: never armed"
      -> arm it offline, it runs on the next boot:
             ./src/environments.sh guest-doctor --install-de <env>
EOF
    ;;
  password)
    if [ -z "$NEW_PW" ]; then
      printf 'New password for %s (input hidden): ' "$GUEST_USER" >&2
      stty -echo 2>/dev/null || true
      read -r NEW_PW
      stty echo 2>/dev/null || true
      printf '\n' >&2
    fi
    [ -n "$NEW_PW" ] || die "Empty password — aborting."
    # Hash once on the host: openssl is a required dependency here and every
    # guest distro accepts sha512-crypt in /etc/shadow.
    HASH="$(openssl passwd -6 "$NEW_PW")" || die "openssl passwd -6 failed."
    for e in $targets; do set_password_one "$e" "$HASH" || rc=1; done
    ;;
  install-de)
    for e in $targets; do install_de_one "$e" || rc=1; done
    ;;
esac

exit "$rc"
;;
set-guest-password)
# =============================================================================
# environments/set-guest-password.sh — force-change a guest's password LIVE
# -----------------------------------------------------------------------------
# Resets the login password (and, by default, root) inside a running VM via the
# qemu-guest-agent — no rebuild, no reboot. Handy when the baked GUEST_PASSWORD
# is wrong/forgotten or you want a distinct password per environment.
#
# Usage:
#   environments/set-guest-password.sh                 # all enabled envs, prompt for pw
#   environments/set-guest-password.sh office          # one env, prompt for pw
#   environments/set-guest-password.sh office 's3cret'  # one env, explicit pw
#   environments/set-guest-password.sh all 's3cret'     # all enabled envs, explicit pw
#   NO_ROOT=1 environments/set-guest-password.sh ...    # change only $GUEST_USER, not root
#
# Requires the guest to be running with qemu-guest-agent up (installed by
# create.sh's cloud-init). If the agent isn't ready yet, wait for first boot to
# finish and retry.
#
# IF THE AGENT NEVER COMES UP, STOP RETRYING THIS SCRIPT. The agent is installed
# by cloud-init, so "no agent" usually means cloud-init did not provision the
# guest at all — in which case there is also no account and no password, and
# nothing here can help. Use the offline path instead, which reads the guest's
# disk from the host and needs neither:
#     virsh shutdown <env>
#     environments/guest-doctor.sh <env>              # what actually went wrong
#     environments/guest-doctor.sh --password <env>   # set the password anyway
# =============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
require_root
load_config
require_cmds virsh
export LIBVIRT_DEFAULT_URI=qemu:///system

want="${1:-all}"
new_pw="${2:-}"

# Which envs? "all" (default) or a single named, enabled env.
if [ "$want" = "all" ]; then
  targets="$(for_each_enabled_env | awk '{print $1}')"
else
  env_enabled "$want" 2>/dev/null || warn "$want is not marked enabled — trying anyway."
  targets="$want"
fi
[ -n "$targets" ] || die "No target environment(s) found."

# Password: from arg, else prompt (no echo). Refuse empty.
if [ -z "$new_pw" ]; then
  printf 'New password for %s (input hidden): ' "$GUEST_USER" >&2
  stty -echo 2>/dev/null || true
  read -r new_pw
  stty echo 2>/dev/null || true
  printf '\n' >&2
fi
[ -n "$new_pw" ] || die "Empty password — aborting."

USER_NAME="${GUEST_USER:-operator}"

set_one() {
  dom="$1"; acct="$2"
  # virsh set-user-password drives the guest agent to change the password.
  if virsh set-user-password "$dom" "$acct" "$new_pw" >/dev/null 2>&1; then
    ok "[$dom] password changed for '$acct'."
  else
    warn "[$dom] could NOT set '$acct' password (is the VM running with the guest agent up?)."
    return 1
  fi
}

rc=0
for e in $targets; do
  virsh dominfo "$e" >/dev/null 2>&1 || { warn "$e: no such domain — skipping."; rc=1; continue; }
  set_one "$e" "$USER_NAME" || rc=1
  [ "${NO_ROOT:-0}" = "1" ] || set_one "$e" root || true
done

[ "$rc" = 0 ] && ok "Done." || warn "Some changes failed — see warnings above."
exit "$rc"
;;
scrub-secrets)
# =============================================================================
# environments/scrub-secrets.sh — remove secrets from the appliance after setup
# -----------------------------------------------------------------------------
# Run this LAST, once the environments are created, isolated, and (optionally)
# their VPNs are up. It blanks every secret in config.env (guest password, WiFi
# PSK, LUKS passphrase, WireGuard private keys) — they've already been consumed
# (baked into the VMs / hashed into wpa_supplicant / applied to LUKS+wg), so the
# appliance no longer needs them at rest. Structural config is kept.
#
# Also removes the generated LUKS key note and the provisioning media (the
# cloud-init seed ISOs AND the Windows autounattend ISOs), which contain the
# plaintext guest password. (These are only read on a guest's first boot;
# recreating a VM regenerates them from config, so removing them is safe once the
# guests are provisioned — but detach them from the domains first if you want
# them gone from the VM definitions too.)
#
# NOTE: environments/isolate.sh now auto-ejects each cloud-init seed the moment
# cloud-init reports done (EJECT_SEEDS=1, the default), so in the normal flow the
# seeds are already gone by the time you run this. SCRUB_SEEDS=1 here is the
# belt-and-braces sweep: it also covers Windows unattend ISOs and any seed a
# guest had not finished consuming when isolate.sh last ran.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
require_root
load_config

log "Scrubbing secrets from config.env ..."
scrub_secrets

# Remove the generated-secrets records (record them elsewhere FIRST!).
for f in /root/luks-key.txt /root/generated-secrets.txt; do
  if [ -f "$f" ]; then
    warn "Removing $f — make sure you recorded everything in it!"
    shred -u "$f" 2>/dev/null || rm -f "$f"
  fi
done

# Optionally wipe seed ISOs (plaintext password). Off by default because they are
# attached to the domains as cdrom; set SCRUB_SEEDS=1 to detach+remove.
if [ "${SCRUB_SEEDS:-0}" = "1" ]; then
  for_each_enabled_env | while read -r env _; do
    # BOTH provisioning-media shapes carry the plaintext password: the Linux
    # cloud-init seed (<env>-seed.iso) and the Windows autounattend answer file
    # (<env>-unattend.iso). Sweep both. scrub-secrets.sh:40 used to name only the
    # seed, so a Windows env kept its plaintext-credential ISO attached forever.
    for media in "$IMAGES_DIR/${env}-seed.iso" "$IMAGES_DIR/${env}-unattend.iso"; do
      # The cdrom's target dev is auto-assigned by libvirt and is NOT always
      # 'sda' (q35 -> sata sda, i440fx -> ide hda). Detaching a hardcoded 'sda'
      # silently no-ops on i440fx, then rm leaves the domain XML pointing at a
      # now-missing ISO and `virsh start` fails. Discover the real target first.
      # `virsh domblklist` prints just two columns (Target, Source), so the
      # target device is $1 — reading $3 matched nothing, the detach silently
      # no-opped for EVERY domain, and the rm below then left the domain XML
      # pointing at a deleted ISO, which makes the next `virsh start` fail.
      tgt="$(virsh domblklist "$env" 2>/dev/null | awk -v f="$media" '$NF==f {print $1; exit}')"
      if [ -n "$tgt" ]; then
        # --config only (persistent XML), by design: a RUNNING domain keeps the
        # cdrom in its live XML until it is restarted and qemu holds the open fd,
        # so the ISO stays readable in-flight but the unlink below is safe. The
        # live-removal path is isolate.sh's auto-eject (which runs the moment
        # cloud-init is done); this manual scrub is the belt-and-braces sweep.
        virsh detach-disk "$env" "$tgt" --config 2>/dev/null \
          || warn "$env: could not detach seed cdrom '$tgt' — leaving $media in place."
      fi
      # Only remove the ISO once the PERSISTENT config no longer references it; a
      # dangling cdrom source is worse than a leftover file. (--inactive: a
      # running domain keeps the cdrom in its live XML until it is restarted, and
      # qemu holds the open fd, so unlinking now is safe.) shred: still plaintext.
      [ -e "$media" ] || continue
      if [ -z "$(virsh domblklist "$env" --inactive 2>/dev/null | awk -v f="$media" '$NF==f {print $1; exit}')" ]; then
        shred -u "$media" 2>/dev/null || rm -f "$media" 2>/dev/null || true
      fi
    done
  done
  log "Provisioning ISOs (cloud-init seed + Windows unattend) detached + shredded (SCRUB_SEEDS=1)."
fi

ok "Secrets scrubbed. config.env keeps only non-sensitive structure."
;;
-h|--help|"") _env_usage; [ -n "$_cmd" ] ;;
*) _env_usage; die "unknown command: $_cmd" ;;
esac
