#!/bin/bash
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
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=../lib/de-install.sh
. "$HERE/../lib/de-install.sh"
# shellcheck source=../lib/guestdisk.sh
. "$HERE/../lib/guestdisk.sh"
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
  _pw_hash="$(openssl passwd -6 "$GUEST_PASSWORD")"
  _sh_pw="${GUEST_PASSWORD//\'/\'\\\'\'}"

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
ssh_pwauth: true
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
  umask 022   # restore: the seed ISO must stay readable by the qemu process
  # Build the NoCloud seed ISO. Prefer cloud-localds; else xorriso's mkisofs
  # (installed via virt-install on Alpine); else genisoimage (Debian path).
  # The volume label MUST be "cidata" for cloud-init NoCloud to pick it up.
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
# create_vm  NAME VARIANT NET VCPU RAM DISKGB BASEIMG HOSTNAME
#   Copies base cloud image to a per-VM disk, resizes, attaches cloud-init seed,
#   imports with virt-install (no interactive install — image is prebuilt).
#   CPU host-passthrough. SPICE graphics (software render; no GPU passthrough).
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
        rm -f "$IMAGES_DIR/${name}.qcow2" "$IMAGES_DIR/${name}-seed.iso" 2>/dev/null || true
        ;;
      *)
        warn "VM $name already exists — skipping (idempotent). Set RECREATE=$name (or RECREATE=1) to rebuild."
        virsh autostart "$name" 2>/dev/null || true
        return
        ;;
    esac
  fi

  vmdisk="$IMAGES_DIR/${name}.qcow2"
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
      _hash="$(openssl passwd -6 "$GUEST_PASSWORD")"
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
      warn "$name: qemu-nbd/nbd unavailable — login depends on cloud-init succeeding. If it does not, see src/environments/guest-doctor.sh."
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
  if [ "$(env_val "$pair" INTUNE 0)" = "1" ] && [ "$(env_val "$pair" OS arch)" != "ubuntu" ]; then
    die "$pair has INTUNE=1 but OS=$(env_val "$pair" OS) — Intune/Entra requires Ubuntu. Set ${pair}_OS=ubuntu."
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
    ./src/environments/guest-doctor.sh <name>

Next: ./src/environments/isolate.sh   (or ./setup-machine.sh 2)
EOF
