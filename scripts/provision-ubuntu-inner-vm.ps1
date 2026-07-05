# Provision Ubuntu inner VM on Hyper-V (nested L2). Run via WinRM from metal host.
param(
  [Parameter(Mandatory = $true)][int]$SiteId,
  [Parameter(Mandatory = $true)][string]$MetalGateway,
  [Parameter(Mandatory = $true)][string]$VhdxUrl,
  [Parameter(Mandatory = $true)][string]$SeedUrl,
  [Parameter(Mandatory = $true)][string]$InnerIp,
  [Parameter(Mandatory = $true)][string]$VmMac,
  [switch]$ForceReinstall,
  [switch]$SkipDownload,
  [switch]$SkipSeed
)

$ErrorActionPreference = "Stop"
Import-Module Hyper-V -ErrorAction Stop
$VmName = "ubuntu-inner"
$SwitchName = "NestedVirt-Lab"
$StateDir = "C:\ProgramData\nested-virt"
$LogFile = Join-Path $StateDir "provision-inner-ubuntu.log"

function Log([string]$Msg) {
  $line = "{0} {1}" -f (Get-Date -Format o), $Msg
  Add-Content -Path $LogFile -Value $line
  Write-Output $line
}

function Ensure-VmmsRunning {
  $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
  if (-not $vmms) {
    throw "vmms service missing - Hyper-V hypervisor not installed. Run enable-hyperv-nested-host.ps1 after KVM XML fix."
  }
  if ($vmms.Status -ne "Running") {
    Start-Service vmms
  }
  Log "vmms RUNNING"
}

function Ensure-LabDns {
  param([int]$Site)
  $labIp = "10.$Site.1.10"
  $dns = @('1.1.1.1', '1.0.0.1')
  $dnsSet = $false
  Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
    if ($_.Name -like '*NestedVirt-Lab*' -or $_.Name -like '*NestedVirt*Lab*') {
      $cur = @(Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ServerAddresses)
      if (-not ($cur -contains '1.1.1.1')) {
        Log "set DNS on $($_.Name) -> $($dns -join ',')"
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $dns
      } else {
        Log "DNS ok on $($_.Name)"
      }
      $dnsSet = $true
    }
  }
  if (-not $dnsSet) {
    Get-NetAdapter | Where-Object {
      $_.Status -eq 'Up' -and $_.Name -notmatch 'vEthernet' -and $_.InterfaceDescription -notmatch 'Hyper-V'
    } | ForEach-Object {
      $have = Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $labIp }
      if ($have) {
        Log "set DNS on uplink $($_.Name) -> $($dns -join ',')"
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $dns
      }
    }
  }
}

function Ensure-ExternalSwitch {
  if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Log "vSwitch $SwitchName exists"
    Ensure-LabDns -Site $SiteId
    return
  }
  $nic = Get-NetAdapter | Where-Object {
    $_.Status -eq "Up" -and
    $_.Name -notmatch "vEthernet" -and
    $_.InterfaceDescription -notmatch "Hyper-V"
  } | Select-Object -First 1
  if (-not $nic) { throw "No suitable host NIC for external vSwitch" }

  $ipCfg = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch "^169\.254\." } | Select-Object -First 1
  $gw = (Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Select-Object -First 1).NextHop

  Log "create external vSwitch $SwitchName on $($nic.Name) ip=$($ipCfg.IPAddress) gw=$gw"
  New-VMSwitch -Name $SwitchName -AllowManagementOS $true -NetAdapterName $nic.Name | Out-Null

  Start-Sleep -Seconds 5
  $vEth = Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" -or $_.InterfaceDescription -match "Hyper-V Virtual Ethernet Adapter" } |
    Select-Object -First 1
  if ($ipCfg -and $vEth -and $vEth.ifIndex -ne $nic.ifIndex) {
    $existing = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $vEth.ifIndex -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -eq $ipCfg.IPAddress }
    if (-not $existing) {
      Log "restore lab IP $($ipCfg.IPAddress) on $($vEth.Name)"
      New-NetIPAddress -InterfaceIndex $vEth.ifIndex -IPAddress $ipCfg.IPAddress -PrefixLength $ipCfg.PrefixLength -DefaultGateway $gw -ErrorAction SilentlyContinue | Out-Null
    }
  }
  Ensure-LabDns -Site $SiteId
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Log "begin site=$SiteId inner_ip=$InnerIp mac=$VmMac hyperv_path=1"

if (-not (Get-WindowsFeature Hyper-V).Installed) {
  throw "Hyper-V feature not installed"
}
Ensure-VmmsRunning
Ensure-ExternalSwitch

$vhdx = Join-Path $StateDir "ubuntu-inner-disk.vhdx"
$seed = Join-Path $StateDir "ubuntu-inner-seed.iso"
$vhdxPart = "$vhdx.part"
$legacyPart = Join-Path $StateDir "ubuntu-inner.vhdx.part"

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
  if ($ForceReinstall) {
    Log "remove existing vm $VmName before vhdx work"
    Stop-VM -Name $VmName -Force -TurnOff -ErrorAction SilentlyContinue
    Remove-VM -Name $VmName -Force
    Start-Sleep -Seconds 3
    foreach ($artifact in @($vhdx, $vhdxPart, $seed, $legacyPart)) {
      if ($SkipDownload -and ($artifact -eq $vhdx -or $artifact -eq $vhdxPart)) {
        Log "keep staged vhdx for SkipDownload size=$((Get-Item $vhdx -ErrorAction SilentlyContinue).Length)"
        continue
      }
      if ($artifact -and (Test-Path $artifact)) {
        Log "force remove stale artifact $artifact"
        Remove-Item $artifact -Force -ErrorAction SilentlyContinue
      }
    }
    if (-not $SkipDownload) {
      Remove-Item (Join-Path $StateDir "ubuntu-inner-disk.vhdx.sha256") -Force -ErrorAction SilentlyContinue
    }
  } else {
    Log "vm $VmName already exists - start if stopped"
    if ((Get-VM -Name $VmName).State -ne "Running") { Start-VM -Name $VmName }
    Ensure-LabDns -Site $SiteId
    Log "PHASE=INNER_UBUNTU_OK vm=$VmName ip=$InnerIp existing=1"
    exit 0
  }
}

if (-not $SkipDownload) {
if ((Test-Path $legacyPart) -and -not (Test-Path $vhdxPart)) {
  Log "adopt legacy vhdx.part"
  Move-Item -Path $legacyPart -Destination $vhdxPart -Force
}
if (Test-Path $vhdxPart) {
  $partLen = (Get-Item $vhdxPart).Length
  if ($partLen -gt 1GB) {
    Log "reuse downloaded vhdx.part size=$partLen"
    Copy-Item -Path $vhdxPart -Destination $vhdx -Force
    Remove-Item $vhdxPart -Force
  } else {
    Log "discard truncated vhdx.part size=$partLen"
    Remove-Item $vhdxPart -Force
  }
}
if (-not (Test-Path $vhdx) -or (Get-Item $vhdx).Length -lt 1GB) {
  if (Test-Path $vhdx) {
    Log "remove stale vhdx before download"
    Remove-Item $vhdx -Force -ErrorAction SilentlyContinue
  }
  Log "download vhdx via curl.exe (to .part then replace)"
  if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe missing on Windows guest"
  }
  & curl.exe -f -L -o $vhdxPart $VhdxUrl
  if ($LASTEXITCODE -ne 0) { throw "VHDX curl download failed exit=$LASTEXITCODE" }
  if (-not (Test-Path $vhdxPart)) { throw "VHDX download failed" }
  if ((Get-Item $vhdxPart).Length -lt 1GB) { throw "VHDX download looks truncated" }
  Copy-Item -Path $vhdxPart -Destination $vhdx -Force
  Remove-Item $vhdxPart -Force
} else {
  Log "reuse existing vhdx size=$((Get-Item $vhdx).Length)"
}
if (-not $SkipSeed) {
Log "download seed iso"
if (-not (Test-Path $seed)) {
  & curl.exe -f -L -o $seed $SeedUrl
  if ($LASTEXITCODE -ne 0) { throw "seed curl download failed exit=$LASTEXITCODE" }
} else {
  Log "reuse existing seed iso"
}
}
} else {
  if (-not (Test-Path $vhdx) -or (Get-Item $vhdx).Length -lt 1GB) {
    throw "SkipDownload set but vhdx missing or too small at $vhdx"
  }
  Log "SkipDownload vhdx size=$((Get-Item $vhdx).Length)"
  if (-not $SkipSeed) {
    if (-not (Test-Path $seed)) {
      Log "download seed iso (SkipDownload path)"
      & curl.exe -f -L -o $seed $SeedUrl
      if ($LASTEXITCODE -ne 0) { throw "seed curl download failed exit=$LASTEXITCODE" }
    } elseif ($ForceReinstall) {
      Log "ForceReinstall refresh seed iso"
      Remove-Item $seed -Force -ErrorAction SilentlyContinue
      & curl.exe -f -L -o $seed $SeedUrl
      if ($LASTEXITCODE -ne 0) { throw "seed curl download failed exit=$LASTEXITCODE" }
    } else {
      Log "reuse existing seed iso"
    }
  } else {
    Log "SkipSeed=1 (credentials+netplan baked in VHDX)"
  }
}

Log "create gen2 vm $VmName on Hyper-V"
New-VM -Name $VmName -MemoryStartupBytes 2GB -Generation 2 -VHDPath $vhdx -SwitchName $SwitchName | Out-Null
Set-VM -Name $VmName -ProcessorCount 2 -AutomaticStartAction Start -AutomaticStopAction ShutDown
Set-VMProcessor -VMName $VmName -ExposeVirtualizationExtensions $false
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false
Set-VMNetworkAdapter -VMName $VmName -StaticMacAddress $VmMac
Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
if (-not $SkipSeed) {
  Add-VMDvdDrive -VMName $VmName -Path $seed
}
$hd = Get-VMHardDiskDrive -VMName $VmName
# Boot from disk; optional nocloud seed ISO when not SkipSeed.
Set-VMFirmware -VMName $VmName -BootOrder $hd
Set-VM -Name $VmName -Notes "nested-virt L2 ubuntu site $SiteId $InnerIp (Hyper-V child)"
Start-VM -Name $VmName
Ensure-LabDns -Site $SiteId
Log "PHASE=INNER_UBUNTU_STARTED vm=$VmName ip=$InnerIp mac=$VmMac layer=hyperv"
