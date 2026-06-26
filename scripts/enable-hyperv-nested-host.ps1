# Enable Hyper-V hypervisor inside a nested Windows guest (after KVM XML fix + reboot).
param(
  [Parameter(Mandatory = $true)][int]$SiteId
)

$ErrorActionPreference = 'Stop'
$LogFile = 'C:\ProgramData\nested-virt\enable-hyperv-nested-host.log'
$LabIp = "10.$SiteId.1.10"
$LabGw = "10.$SiteId.1.1"

function Log([string]$Msg) {
  $line = "{0} {1}" -f (Get-Date -Format o), $Msg
  Add-Content -Path $LogFile -Value $line
  Write-Output $line
}

function Restore-LabIp {
  $nic = Get-NetAdapter | Where-Object {
    $_.Status -eq 'Up' -and $_.Name -notmatch 'vEthernet' -and $_.InterfaceDescription -notmatch 'Hyper-V'
  } | Select-Object -First 1
  if (-not $nic) { Log 'WARN no uplink NIC for lab IP restore'; return }
  $have = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $LabIp }
  if ($have) { Log "lab IP ${LabIp} already on $($nic.Name)"; return }
  Log "restore lab IP ${LabIp} on $($nic.Name)"
  Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^169\.254\.' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
  New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $LabIp -PrefixLength 24 -DefaultGateway $LabGw -ErrorAction Stop | Out-Null
}

New-Item -ItemType Directory -Force -Path 'C:\ProgramData\nested-virt' | Out-Null
Log "begin enable-hyperv-nested-host site=$SiteId lab_ip=$LabIp"

Restore-LabIp

& bcdedit.exe /set hypervisorlaunchtype auto | Out-String | ForEach-Object { Log $_ }

$vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
if ($vmms) {
  Set-Service -Name vmms -StartupType Automatic
  Start-Service -Name vmms -ErrorAction SilentlyContinue
  if ((Get-Service vmms).Status -eq 'Running') {
    Log 'PHASE=VMMS_RUNNING'
    exit 0
  }
}

if (-not (Get-WindowsFeature -Name 'Hyper-V').Installed) {
  Log 'install Hyper-V'
  $null = Install-WindowsFeature -Name 'Hyper-V' -IncludeAllSubFeature -IncludeManagementTools
} else {
  Log 'Hyper-V feature already installed — enable hypervisor only'
  $null = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
}

$vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
if ($vmms -and (Get-Service vmms).Status -eq 'Running') {
  Log 'PHASE=VMMS_RUNNING'
  exit 0
}

Log 'scheduling reboot for hypervisor stack'
Restore-LabIp
shutdown.exe /r /t 45 /c 'nested Hyper-V hypervisor enable'
Log 'PHASE=HYPERV_NESTED_REBOOT_SCHEDULED'
