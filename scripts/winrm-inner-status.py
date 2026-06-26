#!/usr/bin/env python3
import sys
import winrm

guest = sys.argv[1] if len(sys.argv) > 1 else "10.0.1.10"
password = open("/var/lib/nested-virt/win-guest-admin-password").read().strip()
ps = r"""
Get-VM ubuntu-inner -ErrorAction SilentlyContinue | Format-List Name,State,Status,IntegrationServicesState
Get-VMNetworkAdapter -VMName ubuntu-inner -ErrorAction SilentlyContinue | Format-List MacAddress,SwitchName,Status
Get-VMSwitch NestedVirt-Lab -ErrorAction SilentlyContinue | Format-List Name,SwitchType,AllowManagementOS
Get-NetAdapter | Where-Object { $_.Name -match 'NestedVirt|vEthernet|Ethernet' } | Format-Table Name,Status,MacAddress -AutoSize
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -match '^10\.0\.1\.' } | Format-Table InterfaceAlias,IPAddress -AutoSize
Write-Output "ping_gw=$(Test-Connection -ComputerName 10.0.1.1 -Count 1 -Quiet)"
Write-Output "ping_inner=$(Test-Connection -ComputerName 10.0.1.20 -Count 1 -Quiet)"
arp -a | Select-String '10.0.1'
Get-Content C:\ProgramData\nested-virt\provision-inner-ubuntu.log -Tail 15 -ErrorAction SilentlyContinue
"""
s = winrm.Session(
    f"http://{guest}:5985/wsman",
    auth=("Administrator", password),
    transport="ntlm",
    server_cert_validation="ignore",
    read_timeout_sec=90,
)
r = s.run_ps(ps)
sys.stdout.write(r.std_out.decode())
sys.stderr.write(r.std_err.decode())
sys.exit(r.status_code)
