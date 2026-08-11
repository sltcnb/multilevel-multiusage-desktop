#!/bin/sh
# lib/windows-unattend.sh
# -----------------------------------------------------------------------------
# ONE definition of "how a Windows 11 office guest gets provisioned unattended",
# the Windows counterpart to lib/de-install.sh (which is cloud-init/Linux only).
#
# Windows has no cloud-init and no downloadable cloud image, so the Linux path in
# environments/create.sh (fetch qcow2 -> NoCloud seed -> cloud-init) does not
# apply. Instead Windows Setup reads an answer file named autounattend.xml from
# the root of any attached removable/optical media and installs hands-free. This
# file emits that answer file; create.sh wraps it in a small ISO and attaches it
# alongside the operator-supplied Windows ISO.
#
# Deliberate reliability choices (this path CANNOT be pre-seeded or repaired
# offline the way the Linux guests can — there is no /etc/shadow or netplan to
# edit on NTFS — so the install must succeed on the first pass):
#   * TARGET DISK = SATA/AHCI, not virtio. Windows 11 has an inbox AHCI driver,
#     so Setup sees the disk with NO driver injection in WinPE (the single most
#     common unattended-install failure). virtio-blk would need a viostor driver
#     loaded in WinPE from the virtio-win media — fragile and drive-letter
#     dependent. Perf for a desktop is fine on AHCI; the operator can migrate to
#     virtio later if they want.
#   * NIC = e1000e (set in create.sh), also an inbox Windows driver, so the guest
#     has working DHCP/network during OOBE and at first boot with no driver step.
#   * The Win11 hardware gates (TPM 2.0 + Secure Boot + >=4 GB) are SATISFIED by
#     the q35+UEFI+vTPM profile create.sh gives this guest, so NO registry bypass
#     is needed — the install is a supported configuration, not a hack.
#   * virtio-win guest tools (qemu-guest-agent + qxldod + virtio drivers) and the
#     SPICE guest tools (spice-vdagent, for viewer auto-resize) are installed by
#     FirstLogonCommands, scanning drive letters because WinPE/OOBE letters are
#     not stable. qemu-guest-agent is what environments/isolate.sh talks to.
# -----------------------------------------------------------------------------

# win_min_disk_mb — floor for a Windows 11 install (~20 GB OS + headroom). Well
# below the 64 GB create.sh defaults, but a guard against a hand-set tiny disk.
win_min_disk_mb() { printf '30000'; }

# _win_xml_escape STRING — make STRING safe inside an XML text node/attribute.
# The guest password flows into the answer file verbatim, so & < > " ' must be
# entity-escaped or Setup rejects the file (or worse, sets a truncated password).
_win_xml_escape() {
  printf '%s' "${1:-}" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# win_autounattend USER PASS HOSTNAME [LOCALE] [TZ] — print autounattend.xml.
#   USER/PASS    — the local administrator created for the operator (same
#                  GUEST_PASSWORD the Linux guests use).
#   HOSTNAME     — computer name (<=15 chars; caller trims).
#   LOCALE       — Windows locale tag, default en-US.
#   TZ           — Windows time-zone id, default "UTC" (matches the appliance).
win_autounattend() {
  _wu_user="$1"; _wu_pass="$2"; _wu_host="$3"
  _wu_locale="${4:-en-US}"; _wu_tz="${5:-UTC}"
  _wu_user_x="$(_win_xml_escape "$_wu_user")"
  _wu_pass_x="$(_win_xml_escape "$_wu_pass")"
  _wu_host_x="$(_win_xml_escape "$_wu_host")"
  # Windows computer names are <=15 chars and a limited charset; the caller passes
  # an env name (office), which is safe, but trim defensively.
  _wu_host_x="$(printf '%.15s' "$_wu_host_x")"

  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>$_wu_locale</UILanguage></SetupUILanguage>
      <InputLocale>$_wu_locale</InputLocale>
      <SystemLocale>$_wu_locale</SystemLocale>
      <UILanguage>$_wu_locale</UILanguage>
      <UserLocale>$_wu_locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 11 Pro</Value></MetaData>
          </InstallFrom>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>$_wu_user_x</FullName>
        <Organization>Appliance</Organization>
        <!-- Public KMS client setup key for Win11 Pro: lets Setup proceed
             unattended, does NOT activate. Activation is done post-install via
             Entra/Intune or a KMS/MAK key (governance/licensing decision). -->
        <ProductKey><Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key><WillShowUI>OnError</WillShowUI></ProductKey>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$_wu_host_x</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$_wu_locale</InputLocale>
      <SystemLocale>$_wu_locale</SystemLocale>
      <UILanguage>$_wu_locale</UILanguage>
      <UserLocale>$_wu_locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>$_wu_tz</TimeZone>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$_wu_user_x</Name>
            <DisplayName>$_wu_user_x</DisplayName>
            <Group>Administrators</Group>
            <Password><Value>$_wu_pass_x</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$_wu_user_x</Username>
        <Password><Value>$_wu_pass_x</Value><PlainText>true</PlainText></Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Install virtio-win guest tools (qemu-guest-agent + drivers)</Description>
          <CommandLine>cmd /c "for %i in (D E F G H I) do @if exist %i:\virtio-win-guest-tools.exe start /wait %i:\virtio-win-guest-tools.exe /install /passive /norestart"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Install SPICE guest tools (spice-vdagent for viewer auto-resize)</Description>
          <CommandLine>cmd /c "for %i in (D E F G H I) do @if exist %i:\spice-guest-tools.exe start /wait %i:\spice-guest-tools.exe /S"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Ensure the qemu-guest-agent service is running (isolate.sh talks to it)</Description>
          <CommandLine>cmd /c "sc config qemu-ga start= auto &amp; net start qemu-ga"</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XML
}
