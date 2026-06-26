#!/usr/bin/env bash
# Diagnose or clean up Hyper-V inner Ubuntu (L2). Run on metal host.
# usage: diag-hyperv-inner.sh [quick|full|cleanup] [site-id]
set -euo pipefail

MODE="${1:-quick}"
SITE_ID="${2:-${SITE_ID:-0}}"

case "$MODE" in
  quick|full|cleanup) ;;
  [0-9]*) SITE_ID="$MODE"; MODE="quick" ;;
  *)
    echo "usage: diag-hyperv-inner.sh [quick|full|cleanup] [site-id]"
    exit 1
    ;;
esac

GUEST_IP="10.${SITE_ID}.1.10"
INNER_IP="10.${SITE_ID}.1.20"
GATEWAY_IP="10.${SITE_ID}.1.1"
INNER_MAC="$(printf '52:54:00:20:%02x:20' "$((10#${SITE_ID}))")"
LAB_OCTET="10.${SITE_ID}.1"
PASS_FILE="${PASS_FILE:-/var/lib/nested-virt/win-guest-admin-password}"

ensure_pywinrm() {
  pip3 install -q pywinrm 2>/dev/null \
    || pip3 install --break-system-packages -q pywinrm 2>/dev/null \
    || true
}

metal_checks() {
  echo "=== metal (site ${SITE_ID}) ==="
  ping -c2 -W2 "$GUEST_IP" || true
  ping -c2 -W2 "$INNER_IP" || true
  ip neigh show "$INNER_IP" || true
  timeout 5 tcpdump -i br-default -c 20 \
    "ether host ${INNER_MAC} or host ${INNER_IP}" 2>/dev/null || true
  echo "=== dnsmasq ==="
  grep -E 'dhcp-host|interface' /etc/nested-virt-dnsmasq.conf || true
}

winrm_quick() {
  ensure_pywinrm
  python3 - "$GUEST_IP" "$PASS_FILE" "$INNER_IP" "$GATEWAY_IP" "$LAB_OCTET" <<'PY'
import sys, winrm

guest, pw, inner, gateway, lab_octet = sys.argv[1:6]
lab_regex = lab_octet.replace(".", r"\.")
password = open(pw).read().strip()
ps = f"""
Write-Output '=== vm ==='
Get-VM ubuntu-inner -ErrorAction SilentlyContinue | Format-List Name,State,Status,IntegrationServicesState,Generation
Get-VMNetworkAdapter -VMName ubuntu-inner -ErrorAction SilentlyContinue | Format-List MacAddress,SwitchName,Status,IPAddresses
Write-Output '=== switch ==='
Get-VMSwitch NestedVirt-Lab -ErrorAction SilentlyContinue | Format-List Name,SwitchType,AllowManagementOS
Get-NetAdapter | Where-Object {{ $_.Name -match 'NestedVirt|vEthernet|Ethernet' }} | Format-Table Name,Status,MacAddress -AutoSize
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {{ $_.IPAddress -match '^{lab_regex}' }} | Format-Table InterfaceAlias,IPAddress -AutoSize
Write-Output "ping_gw=$(Test-Connection -ComputerName {gateway} -Count 1 -Quiet)"
Write-Output "ping_inner=$(Test-Connection -ComputerName {inner} -Count 1 -Quiet)"
arp -a | Select-String '{lab_octet}'
Get-ChildItem C:\\ProgramData\\nested-virt\\ubuntu-inner* -ErrorAction SilentlyContinue | Select-Object Name,Length
Get-Content C:\\ProgramData\\nested-virt\\provision-inner-ubuntu.log -Tail 15 -ErrorAction SilentlyContinue
"""
s = winrm.Session(
    f"http://{guest}:5985/wsman",
    auth=("Administrator", password),
    transport="ntlm",
    server_cert_validation="ignore",
    read_timeout_sec=120,
    operation_timeout_sec=90,
)
r = s.run_ps(ps)
print(r.std_out.decode())
if r.std_err:
    print(r.std_err.decode())
PY
}

winrm_full() {
  ensure_pywinrm
  python3 - "$GUEST_IP" "$PASS_FILE" "$INNER_IP" "$GATEWAY_IP" "$LAB_OCTET" <<'PY'
import sys, winrm

guest, pw, inner, gateway, lab_octet = sys.argv[1:6]
lab_regex = lab_octet.replace(".", r"\.")
password = open(pw).read().strip()
ps = f"""
Write-Output '=== vm ==='
Get-VM ubuntu-inner -ErrorAction SilentlyContinue | Format-List Name,State,Status,IntegrationServicesState
Get-VMNetworkAdapter -VMName ubuntu-inner -ErrorAction SilentlyContinue | Format-List MacAddress,SwitchName,Status,IPAddresses,SwitchId
Write-Output '=== switch ==='
Get-VMSwitch NestedVirt-Lab -ErrorAction SilentlyContinue | Format-List Name,SwitchType,NetAdapterInterfaceDescription,AllowManagementOS
Get-NetAdapter | Where-Object {{ $_.Name -match 'NestedVirt|vEthernet|Ethernet' }} | Format-Table Name,Status,MacAddress,LinkSpeed -AutoSize
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {{ $_.IPAddress -match '^{lab_regex}' }} | Format-Table InterfaceAlias,IPAddress,PrefixLength -AutoSize
Write-Output '=== ping gw ==='
Test-Connection -ComputerName {gateway} -Count 1 -Quiet
Write-Output '=== ping inner ==='
Test-Connection -ComputerName {inner} -Count 2 -Quiet
Write-Output '=== arp ==='
arp -a | Select-String '{lab_octet}'
Get-Content C:\\ProgramData\\nested-virt\\provision-inner-ubuntu.log -Tail 30 -ErrorAction SilentlyContinue
"""
s = winrm.Session(
    f"http://{guest}:5985/wsman",
    auth=("Administrator", password),
    transport="ntlm",
    server_cert_validation="ignore",
    read_timeout_sec=120,
)
r = s.run_ps(ps)
print(r.std_out.decode())
if r.std_err:
    print(r.std_err.decode())
PY
}

winrm_cleanup() {
  ensure_pywinrm
  python3 - "$GUEST_IP" "$PASS_FILE" <<'PY'
import sys, winrm

guest, pw = sys.argv[1:3]
password = open(pw).read().strip()
ps = """
Import-Module Hyper-V -ErrorAction SilentlyContinue
Get-VM -Name ubuntu-inner -ErrorAction SilentlyContinue | ForEach-Object {
  Stop-VM $_ -Force -TurnOff
  Remove-VM $_ -Force
}
Start-Sleep -Seconds 3
Remove-Item C:\\ProgramData\\nested-virt\\ubuntu-inner.vhdx -Force -ErrorAction SilentlyContinue
Remove-Item C:\\ProgramData\\nested-virt\\ubuntu-inner.vhdx.part -Force -ErrorAction SilentlyContinue
Remove-Item C:\\ProgramData\\nested-virt\\ubuntu-inner-seed.iso -Force -ErrorAction SilentlyContinue
Remove-Item C:\\ProgramData\\nested-virt\\ubuntu-inner-disk.vhdx -Force -ErrorAction SilentlyContinue
Get-ChildItem C:\\ProgramData\\nested-virt\\ -ErrorAction SilentlyContinue | Select-Object Name,Length
'cleanup ok'
"""
s = winrm.Session(
    f"http://{guest}:5985/wsman",
    auth=("Administrator", password),
    transport="ntlm",
    server_cert_validation="ignore",
    read_timeout_sec=300,
    operation_timeout_sec=280,
)
r = s.run_ps(ps)
print(r.std_out.decode())
if r.std_err:
    print(r.std_err.decode())
PY
}

case "$MODE" in
  quick)
    winrm_quick
    ;;
  full)
    metal_checks
    winrm_full
    ;;
  cleanup)
    winrm_cleanup
    ;;
esac
