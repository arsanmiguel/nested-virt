#!/usr/bin/env bash
# Check Hyper-V inner VM status on Windows guest via WinRM.
set -euo pipefail
GUEST_IP="${1:-10.0.1.10}"
PASS_FILE="${PASS_FILE:-/var/lib/nested-virt/win-guest-admin-password}"
pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true
python3 - "$GUEST_IP" "$PASS_FILE" <<'PY'
import sys, winrm
guest, pw = sys.argv[1:3]
password = open(pw).read().strip()
ps = """
Get-VM ubuntu-inner -ErrorAction SilentlyContinue | Format-List Name,State,Generation
Get-ChildItem C:\\ProgramData\\nested-virt\\ubuntu-inner* -ErrorAction SilentlyContinue | Select-Object Name,Length
"""
s = winrm.Session(f"http://{guest}:5985/wsman", auth=("Administrator", password),
                  transport="ntlm", server_cert_validation="ignore", read_timeout_sec=60)
r = s.run_ps(ps)
print(r.std_out.decode())
print(r.std_err.decode())
PY
