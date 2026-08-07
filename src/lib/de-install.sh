#!/bin/sh
# lib/de-install.sh
# -----------------------------------------------------------------------------
# ONE definition of "how a guest gets a desktop", shared by:
#   * environments/create.sh    — bakes it into the cloud-init seed
#   * environments/guest-doctor.sh — drops it straight into a guest disk when
#                                 cloud-init never ran at all
#
# It used to live only inside create.sh, as printf format strings full of \n
# escapes nested in YAML nested in shell. That is unreviewable, it is why the
# installer could not be reused by any repair path, and every fix to it had to
# be made blind. Here it is plain text emitted by plain functions.
# -----------------------------------------------------------------------------

# de_resolve OS DE — set DE_PKGS / DE_DM / DE_SESSION for this distro+desktop.
# Package names differ per distro; the display manager and session names are
# what the autologin drop-in below needs. Returns 1 for DE=none.
# shellcheck disable=SC2034  # DE_SESSION is read by this file's callers.
de_resolve() {
  _os="$1"; _de="$2"
  [ "$_de" != "none" ] && [ -n "$_de" ] || return 1
  case "$_os" in
    ubuntu)
      case "$_de" in
        xfce4) DE_PKGS="xubuntu-desktop-minimal lightdm"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
        gnome) DE_PKGS="ubuntu-desktop-minimal gdm3";     DE_DM="gdm3";    DE_SESSION="ubuntu" ;;
        kde)   DE_PKGS="kde-plasma-desktop sddm";         DE_DM="sddm";    DE_SESSION="plasma" ;;
        mate)  DE_PKGS="ubuntu-mate-desktop lightdm";     DE_DM="lightdm"; DE_SESSION="mate" ;;
        lxqt)  DE_PKGS="lubuntu-desktop sddm";            DE_DM="sddm";    DE_SESSION="lxqt" ;;
        *) warn "Unknown DE '$_de'; defaulting to xfce4."
           DE_PKGS="xubuntu-desktop-minimal lightdm"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
      esac ;;
    debian)
      case "$_de" in
        xfce4) DE_PKGS="xorg xfce4 xfce4-goodies lightdm"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
        gnome) DE_PKGS="gnome-core gdm3";                  DE_DM="gdm3";    DE_SESSION="gnome" ;;
        kde)   DE_PKGS="kde-plasma-desktop sddm";          DE_DM="sddm";    DE_SESSION="plasma" ;;
        mate)  DE_PKGS="mate-desktop-environment lightdm"; DE_DM="lightdm"; DE_SESSION="mate" ;;
        lxqt)  DE_PKGS="lxqt sddm";                        DE_DM="sddm";    DE_SESSION="lxqt" ;;
        *) warn "Unknown DE '$_de'; defaulting to xfce4."
           DE_PKGS="xorg xfce4 lightdm"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
      esac ;;
    *)  # arch — needs the xorg group spelled out, and the greeter package
      case "$_de" in
        xfce4) DE_PKGS="xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
        gnome) DE_PKGS="gnome gdm";                                            DE_DM="gdm";     DE_SESSION="gnome" ;;
        kde)   DE_PKGS="plasma-meta sddm";                                     DE_DM="sddm";    DE_SESSION="plasma" ;;
        mate)  DE_PKGS="xorg mate mate-extra lightdm lightdm-gtk-greeter";     DE_DM="lightdm"; DE_SESSION="mate" ;;
        lxqt)  DE_PKGS="xorg lxqt sddm";                                       DE_DM="sddm";    DE_SESSION="lxqt" ;;
        *) warn "Unknown DE '$_de'; defaulting to xfce4."
           DE_PKGS="xorg xfce4 lightdm lightdm-gtk-greeter"; DE_DM="lightdm"; DE_SESSION="xfce" ;;
      esac ;;
  esac
  return 0
}

# de_min_disk_mb DE — rough floor for "this desktop can actually be unpacked".
# A full ubuntu-mate-desktop plus Edge is ~6 GiB installed on top of a ~2 GiB
# base, and create.sh will happily hand a guest a 10 GiB disk (its DISK_GB
# fallback is 10, and detect-and-install's auto-split floor is 8). apt then dies
# part-way with "You don't have enough free space", which reads in the log as an
# ordinary package error and left the VM desktop-less with no obvious cause.
# Check it up front and say the real reason.
de_min_disk_mb() {
  case "$1" in
    gnome|kde|mate) printf '7000' ;;
    lxqt|xfce4)     printf '5000' ;;
    *)              printf '5000' ;;
  esac
}

# de_script OS DE — print /usr/local/sbin/appliance-install-de.sh.
#
# Design notes, all of them scars:
#  * A LOCK. The unit below is enabled for retries AND cloud-init runs this
#    script directly on the first boot. Two concurrent apt runs would deadlock
#    on the dpkg lock, so whoever gets there second exits quietly.
#  * A SPACE PRE-FLIGHT, so "the disk is too small" says so instead of hiding
#    inside apt's output.
#  * dpkg REPAIR first. An install killed part-way (the old code let cloud-init
#    reboot mid-apt) leaves dpkg interrupted, and every later attempt then fails
#    with "dpkg was interrupted" forever.
#  * The display manager is enabled and the default target switched, but the DM
#    is NOT started synchronously here — see de_unit for why.
de_script() {
  _os="$1"; _de="$2"
  de_resolve "$_os" "$_de" || return 1
  _min="$(de_min_disk_mb "$_de")"
  # spice-vdagent rides along with every desktop: it is what lets the guest track
  # the viewer's window size (virt-viewer --auto-resize). Without it the guest is
  # stuck at a fixed low resolution that the viewer scales up — the pixelated,
  # doesn't-fill-the-screen symptom. Same package name on apt and Arch.
  _pkgs="$DE_PKGS spice-vdagent"
  if [ "$(os_family "$_os")" = "apt" ]; then
    _install="DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold $_pkgs"
    _refresh="apt-get update"
    _repair="dpkg --configure -a || true
apt-get -f install -y || true"
  else
    _install="pacman -Sy --noconfirm --needed $_pkgs"
    _refresh="pacman -Sy --noconfirm"
    _repair="rm -f /var/lib/pacman/db.lck || true"
  fi

  cat <<EOF
#!/bin/sh
# Appliance desktop installer — generated by lib/de-install.sh. Retried by
# appliance-de.service until the repos are reachable, then self-disables.
exec >>/var/log/de-install.log 2>&1
echo "=== [de] \$(date -u '+%Y-%m-%dT%H:%M:%SZ') attempt (os=$_os de=$_de) ==="

[ -f /var/lib/appliance-de.done ] && { echo "[de] already installed - nothing to do"; exit 0; }

# Only one attempt at a time: cloud-init runs this directly on the first boot
# while appliance-de.service may also fire it. mkdir is the atomic test.
if ! mkdir /run/appliance-de.lock 2>/dev/null; then
  echo "[de] another attempt already running - skipping"; exit 0
fi
trap 'rmdir /run/appliance-de.lock 2>/dev/null' EXIT INT TERM HUP

free_mb=\$(df -Pm / | awk 'NR==2 {print \$4}')
echo "[de] free space on /: \${free_mb}MB (need >= $_min MB for $_de)"
if [ "\${free_mb:-0}" -lt $_min ]; then
  echo "[de] FATAL - not enough disk for the $_de desktop."
  echo "[de] The guest disk is too small. Give this env a bigger disk on the HOST:"
  echo "[de]   set <env>_DISK_GB in config.env, then RECREATE=<env> ./src/environments/create.sh"
  echo "[de] Not retrying - a retry cannot create disk space."
  touch /var/lib/appliance-de.nospace
  exit 0
fi

$_repair

if ! $_refresh; then
  echo "[de] package index refresh FAILED - no repos reachable yet."
  echo "[de] (no internet? captive portal not cleared? check the HOST uplink)"
  echo "[de] will retry in 30s"
  exit 1
fi

if ! $_install; then
  echo "[de] package install FAILED - will retry in 30s"
  exit 1
fi

systemctl set-default graphical.target || true
systemctl enable $DE_DM || true
# The daemon side of the resize/clipboard agent; the per-session client is
# autostarted by the desktop. Without it running, --auto-resize does nothing.
systemctl enable --now spice-vdagentd || true
touch /var/lib/appliance-de.done
systemctl disable appliance-de.service || true
echo "[de] OK - desktop installed, display manager '$DE_DM' enabled"

# Bring the desktop up now if we are NOT inside cloud-init's first boot. During
# cloud-init, starting graphical.target synchronously can deadlock against the
# transaction that is still bringing up multi-user.target — cloud-init reboots
# once on its own (power_state) and the desktop comes up there instead.
if [ ! -e /run/cloud-init/status.json ] || [ -f /run/cloud-init/result.json ]; then
  systemctl start graphical.target --no-block || true
fi
EOF
}

# de_unit — print /etc/systemd/system/appliance-de.service.
#
# The installer is NEVER waited on synchronously by cloud-init. It used to be
# (`systemctl start --wait appliance-de.service`), and that is a trap: the unit
# carries Restart=on-failure, so on a guest with no internet yet systemd keeps
# restarting it and `--wait` never returns — cloud-final hangs for the whole
# boot, every boot. cloud-init calls the SCRIPT directly instead (bounded, it
# either installs or returns non-zero), and this unit exists purely to retry on
# later boots.
de_unit() {
  cat <<'EOF'
[Unit]
Description=Appliance desktop install (retries until the repos are reachable)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/appliance-de.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/appliance-install-de.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

# de_autologin_path DM — where the autologin drop-in for this DM goes.
de_autologin_path() {
  case "$1" in
    lightdm) printf '/etc/lightdm/lightdm.conf.d/50-appliance-autologin.conf' ;;
    gdm3)    printf '/etc/gdm3/custom.conf' ;;
    gdm)     printf '/etc/gdm/custom.conf' ;;
    sddm)    printf '/etc/sddm.conf.d/50-appliance-autologin.conf' ;;
  esac
}

# de_autologin_content DM USER SESSION — the drop-in itself.
# lightdm gets a conf.d drop-in rather than a rewritten lightdm.conf, so a
# distro's own seat configuration survives.
de_autologin_content() {
  case "$1" in
    lightdm) printf '[Seat:*]\nautologin-user=%s\nautologin-session=%s\nautologin-user-timeout=0\n' "$2" "$3" ;;
    gdm3|gdm) printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$2" ;;
    sddm)    printf '[Autologin]\nUser=%s\nSession=%s\n' "$2" "$3" ;;
  esac
}

# de_autologin_extra_cmd DM USER — a shell command the guest must ALSO run for
# autologin to work, or empty. Arch's lightdm refuses to autologin a user who is
# not in the `autologin` group, and that group does not exist until something
# creates it — so a correct-looking drop-in silently did nothing and the env sat
# at a greeter.
de_autologin_extra_cmd() {
  case "$1" in
    lightdm) printf "groupadd -r autologin 2>/dev/null || true; gpasswd -a %s autologin 2>/dev/null || true" "$2" ;;
    *) : ;;
  esac
}
