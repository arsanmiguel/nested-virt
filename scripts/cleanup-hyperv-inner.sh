#!/usr/bin/env bash
# Remove stale Hyper-V inner VM artifacts on Windows guest before redeploy.
set -euo pipefail
GUEST_IP="${1:-10.0.1.10}"
PASS_FILE="${PASS_FILE:-/var/lib/nested-virt/win-guest-admin-password}"
pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true
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
Get-ChildItem C:\\ProgramData\\nested-virt\\ -ErrorAction SilentlyContinue | Select-Object Name,Length
'cleanup ok'
"""
s = winrm.Session(f"http://{guest}:5985/wsman", auth=("Administrator", password),
                  transport="ntlm", server_cert_validation="ignore",
                  read_timeout_sec=300, operation_timeout_sec=280)
r = s.run_ps(ps)
print(r.std_out.decode())
print(r.std_err.decode())
PY
