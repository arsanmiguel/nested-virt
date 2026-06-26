# Runs on first logon from autounattend (copied to guest via supplemental ISO).
$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\enable-hyperv.log'
function Log($m) { "$(Get-Date -Format o) $m" | Tee-Object -FilePath $log -Append }

Log 'enable-hyperv begin'
$feat = Get-WindowsFeature Hyper-V
if (-not $feat.Installed) {
  Log 'Installing Hyper-V'
  Install-WindowsFeature Hyper-V -IncludeManagementTools | Out-File -FilePath $log -Append
  Log 'Hyper-V installed — reboot required'
  shutdown /r /t 30 /c 'Hyper-V install complete'
} else {
  Log 'Hyper-V already installed'
}
Log 'enable-hyperv done'
