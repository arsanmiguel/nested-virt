# Idempotent lab DNS on Windows Hyper-V host (post-CSE: metal dnsmasq is DHCP-only, port=0).
# Sets public resolvers on vEthernet (NestedVirt-Lab) and any uplink NIC carrying 10.{site}.1.10.
param(
  [Parameter(Mandatory = $true)][int]$SiteId
)

$ErrorActionPreference = 'Stop'
$LabIp = "10.$SiteId.1.10"
$DnsServers = @('1.1.1.1', '1.0.0.1')
$LogFile = 'C:\ProgramData\nested-virt\ensure-lab-guest-dns.log'

function Log([string]$Msg) {
  $line = "{0} {1}" -f (Get-Date -Format o), $Msg
  Add-Content -Path $LogFile -Value $line
  Write-Output $line
}

function Set-LabDnsOnAdapter([int]$IfIndex, [string]$Name) {
  $cur = @(Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty ServerAddresses)
  if ($cur -contains '1.1.1.1' -and $cur -contains '1.0.0.1') {
    Log "DNS ok on ${Name} ($($DnsServers -join ','))"
    return
  }
  Log "set DNS on ${Name} -> $($DnsServers -join ',')"
  Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses $DnsServers
}

New-Item -ItemType Directory -Force -Path 'C:\ProgramData\nested-virt' | Out-Null
Log "begin site=$SiteId lab_ip=$LabIp"

Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
  $name = $_.Name
  if ($name -like '*NestedVirt-Lab*' -or $name -like '*NestedVirt*Lab*') {
    Set-LabDnsOnAdapter -IfIndex $_.ifIndex -Name $name
    return
  }
}

Get-NetAdapter | Where-Object {
  $_.Status -eq 'Up' -and
  $_.Name -notmatch 'vEthernet' -and
  $_.InterfaceDescription -notmatch 'Hyper-V'
} | ForEach-Object {
  $haveLab = Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $LabIp }
  if ($haveLab) {
    Set-LabDnsOnAdapter -IfIndex $_.ifIndex -Name $_.Name
  }
}

Log 'PHASE=LAB_GUEST_DNS_OK'
