#!/usr/bin/env bash
set -euo pipefail
GUEST_IP="${1:-10.0.1.10}"
INNER_IP="${2:-10.0.1.20}"
PASS_FILE="${PASS_FILE:-/var/lib/nested-virt/win-guest-admin-password}"
echo "=== metal ==="
ping -c2 -W2 "$GUEST_IP" || true
ping -c2 -W2 "$INNER_IP" || true
ip neigh show "$INNER_IP" || true
timeout 5 tcpdump -i br-default -c 20 "ether host 52:54:00:20:00:20 or host ${INNER_IP}" 2>/dev/null || true
echo "=== dnsmasq ==="
grep -E 'dhcp-host|interface' /etc/nested-virt-dnsmasq.conf || true
pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true
python3 - "$GUEST_IP" "$PASS_FILE" "$INNER_IP" <<'PY'
import sys, winrm
guest, pw, inner = sys.argv[1:4]
password = open(pw).read().strip()
ps = r"""
Write-Output '=== vm ==='
Get-VM ubuntu-inner | Format-List Name,State,Status,IntegrationServicesState
Get-VMNetworkAdapter -VMName ubuntu-inner | Format-List MacAddress,SwitchName,Status,IPAddresses,SwitchId
Write-Output '=== switch ==='
Get-VMSwitch NestedVirt-Lab | Format-List Name,SwitchType,NetAdapterInterfaceDescription,AllowManagementOS
Get-NetAdapter | Where-Object {$_.Name -match 'NestedVirt|vEthernet|Ethernet'} | Format-Table Name,Status,MacAddress,LinkSpeed -AutoSize
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -match '^10\.0\.1\.'} | Format-Table InterfaceAlias,IPAddress,PrefixLength -AutoSize
Write-Output '=== ping gw ==='
Test-Connection -ComputerName 10.0.1.1 -Count 1 -Quiet
Write-Output '=== ping inner ==='
Test-Connection -ComputerName """ + inner + r""" -Count 2 -Quiet
Write-Output '=== arp ==='
arp -a | Select-String '10.0.1'
"""
s = winrm.Session(f"http://{guest}:5985/wsman", auth=("Administrator", password),
                  transport="ntlm", server_cert_validation="ignore", read_timeout_sec=120)
r = s.run_ps(ps)
print(r.std_out.decode())
if r.std_err:
    print(r.std_err.decode())
PY
