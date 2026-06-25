#!/usr/bin/env bash
# Open Windows guest firewall for lab ICMP/WinRM (runs on metal host).
set -euo pipefail

GUEST_IP="${1:-}"
PS1="${2:-/tmp/open-guest-firewall.ps1}"
PASS_FILE="${3:-/var/lib/nested-virt/win-guest-admin-password}"

if [[ -z "$GUEST_IP" || ! -f "$PASS_FILE" || ! -f "$PS1" ]]; then
  echo "usage: apply-guest-firewall.sh <guest-ip> [ps1-path] [password-file]"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y python3-pip >/dev/null 2>&1 || true
pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true

python3 - "$GUEST_IP" "$PASS_FILE" <<'PY'
import sys
import winrm

guest, pass_file = sys.argv[1:3]
password = open(pass_file).read().strip()
s = winrm.Session(
    f"http://{guest}:5985/wsman",
    auth=("Administrator", password),
    transport="ntlm",
    server_cert_validation="ignore",
    read_timeout_sec=120,
    operation_timeout_sec=90,
)
cmds = [
    r'netsh advfirewall firewall add rule name="NestedVirt-ICMP-In" protocol=icmpv4:8,any dir=in action=allow remoteip=10.0.0.0/8',
    r'netsh advfirewall firewall add rule name="NestedVirt-WinRM-In" protocol=tcp dir=in localport=5985 action=allow remoteip=10.0.0.0/8',
    r'netsh advfirewall firewall add rule name="NestedVirt-RDP-In" protocol=tcp dir=in localport=3389 action=allow remoteip=10.0.0.0/8',
    r'powershell -Command "Enable-NetFirewallRule -DisplayGroup File` and` Printer` Sharing"',
]
for cmd in cmds:
    r = s.run_cmd("cmd.exe", ["/c", cmd])
    sys.stdout.write(r.std_out.decode(errors="replace"))
    sys.stderr.write(r.std_err.decode(errors="replace"))
    if r.status_code:
        sys.exit(r.status_code)
print(f"PHASE=GUEST_FW_OK ip={guest}")
PY
