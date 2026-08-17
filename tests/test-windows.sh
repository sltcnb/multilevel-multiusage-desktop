#!/bin/sh
# tests/test-windows.sh — the Windows 11 office path in environments/create.sh.
# Windows diverges completely from the Linux cloud-init path: an ISO install on
# a q35 + UEFI + vTPM profile, driven by a generated autounattend.xml. This
# pins the virt-install profile and the answer file so a refactor cannot quietly
# turn the Win11-specific bits back into the SeaBIOS/cloud-init assumptions.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== environments/create.sh (Windows 11 office) =="

# --- happy path ---------------------------------------------------------------
new_sandbox
# Host prerequisites for the full q35+UEFI+vTPM profile: swtpm is stubbed on the
# PATH; give create.sh a real OVMF loader to find so the EXPLICIT-loader path is
# exercised (not the autoselect fallback). The container is disposable + root.
mkdir -p /usr/share/OVMF
: > /usr/share/OVMF/OVMF_CODE.fd
: > /usr/share/OVMF/OVMF_VARS.fd

# office -> Windows 11 (the other two envs stay as the default Linux guests; the
# Windows assertions below match only the office/virt-install line).
cfg_set office_OS windows
cfg_set office_DE none
touch "$SANDBOX/win11.iso"
cfg_set WINDOWS_ISO "$SANDBOX/win11.iso"

"$SANDBOX/src/environments.sh" create > "$SANDBOX/win.out" 2>&1 && rc=0 || rc=$?
assert_eq "create.sh completes for a Windows 11 office env" 0 "$rc"
[ "$rc" = 0 ] || sed 's/^/    /' "$SANDBOX/win.out"

L="$STUB_LOG"
# The office (Windows) virt-install line only — the other two envs are Linux and
# legitimately carry `--machine pc`, so a negative check must look at office alone.
grep -F -- "--name office" "$L" > "$SANDBOX/office-vi.log" 2>/dev/null || : > "$SANDBOX/office-vi.log"
assert_not_contains "Windows does NOT use the SeaBIOS pc machine (office line)" "$SANDBOX/office-vi.log" "machine pc"
assert_contains_fixed "uses the win11 osinfo profile"                 "$L" "--osinfo win11"
assert_contains_fixed "q35 machine (Win11 needs it, not the pc/SeaBIOS Linux uses)" "$L" "--machine q35"
assert_contains_fixed "attaches an emulated TPM 2.0"                  "$L" "backend.type=emulator,backend.version=2.0,model=tpm-crb"
assert_contains_fixed "UEFI via the explicit OVMF loader (Alpine has no fw JSON)" "$L" "loader=/usr/share/OVMF/OVMF_CODE.fd"
assert_contains_fixed "nvram template from OVMF_VARS"                 "$L" "nvram.template=/usr/share/OVMF/OVMF_VARS.fd"
assert_contains_fixed "target disk is SATA (inbox driver, no WinPE injection)" "$L" "bus=sata"
assert_contains_fixed "NIC is e1000e (inbox driver, network at OOBE)" "$L" "model=e1000e"
assert_contains_fixed "boots the operator's Windows install ISO"      "$L" "device=cdrom,path=$SANDBOX/win11.iso"
assert_contains_fixed "attaches virtio-win (drivers + qemu-guest-agent)" "$L" "virtio-win.iso"
assert_contains_fixed "attaches the generated answer-file ISO"        "$L" "office-unattend.iso"
assert_not_contains   "no cloud-init seed is built for Windows"       "$SANDBOX/office-vi.log" "office-seed.iso"

# the answer file was actually built and is valid, with our account + hostname
ISO="$SANDBOX/images/office-unattend.iso"
assert_ok "the autounattend ISO was built" test -f "$ISO"
UA="$SANDBOX/autounattend.xml"
xorriso -osirrox on -indev "$ISO" -extract /autounattend.xml "$UA" >/dev/null 2>&1 \
  || xorriso -osirrox on -indev "$ISO" -extract /AUTOUNATTEND.XML "$UA" >/dev/null 2>&1
assert_ok        "autounattend.xml is well-formed XML" python3 -c "import xml.dom.minidom; xml.dom.minidom.parse('$UA')"
assert_contains  "answer file creates the operator local account" "$UA" "<Name>operator</Name>"
assert_contains  "answer file names the computer"                 "$UA" "<ComputerName>office</ComputerName>"
assert_contains  "answer file enables autologon"                  "$UA" "<AutoLogon>"
assert_contains  "answer file installs guest tools on first logon" "$UA" "virtio-win-guest-tools.exe"
# the plaintext staging copy is gone, like the cloud-init user-data
if [ -f "$SANDBOX/cache/unattend-office/autounattend.xml" ]; then
  _b "the plaintext autounattend staging copy is shredded after the ISO is built"
else
  _g "the plaintext autounattend staging copy is shredded after the ISO is built"
fi

# --- fail closed: OS=windows with no ISO --------------------------------------
new_sandbox
cfg_set office_OS windows
cfg_set WINDOWS_ISO ""
"$SANDBOX/src/environments.sh" create > "$SANDBOX/noiso.out" 2>&1 && norc=0 || norc=$?
if [ "$norc" -ne 0 ]; then _g "create.sh refuses a Windows env with no WINDOWS_ISO"
else _b "create.sh refuses a Windows env with no WINDOWS_ISO"; fi
assert_contains "and the refusal names WINDOWS_ISO" "$SANDBOX/noiso.out" "WINDOWS_ISO"

summary
