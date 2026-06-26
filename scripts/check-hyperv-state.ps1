$ErrorActionPreference = 'SilentlyContinue'
Write-Output "=== hypervisorlaunchtype ==="
& bcdedit.exe /enum {current} | Select-String hypervisorlaunchtype
Write-Output "=== Hyper-V feature ==="
(Get-WindowsFeature Hyper-V | Select-Object Name, InstallState) | Format-List | Out-String
Write-Output "=== vmms ==="
& sc.exe query vmms
Write-Output "=== lab IP ==="
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -match '^10\.' } | Format-Table -AutoSize | Out-String
