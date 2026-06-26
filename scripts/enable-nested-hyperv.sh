#!/usr/bin/env bash
# Enable nested Hyper-V inside Windows KVM guest (wrapper — see fix-kvm-nested-hyperv-xml.sh + enable-hyperv-nested-host.ps1).
set -euo pipefail

GUEST_IP="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS_FILE="${PASS_FILE:-/var/lib/nested-virt/win-guest-admin-password}"
TIMING_LOG=/var/log/amazon/launch-timing.log

log() { echo "$(date -Iseconds) NESTED_HV $*" | tee -a "$TIMING_LOG"; }

: "${GUEST_IP:?usage: enable-nested-hyperv.sh <guest-ip>}"

if virsh dumpxml "${VM_NAME:-win-hv-nested}" 2>/dev/null | grep -q "Skylake-Server-noTSX-IBRS"; then
  log "KVM XML already nested-ready (Skylake-noTSX) — skip fix-kvm patch"
else
  "${SCRIPT_DIR}/fix-kvm-nested-hyperv-xml.sh"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y python3-pip >/dev/null 2>&1 || true
pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true

log "waiting for WinRM on ${GUEST_IP}..."
for _ in $(seq 1 48); do
  ping -c1 -W2 "$GUEST_IP" >/dev/null 2>&1 || { sleep 10; continue; }
  python3 - "$GUEST_IP" "$PASS_FILE" "${SCRIPT_DIR}/enable-hyperv-nested-host.ps1" <<'PY' && break
import sys, time, winrm
guest, pw, ps_path = sys.argv[1:4]
site_id = int(guest.split(".")[1])
password = open(pw).read().strip()
body = open(ps_path).read()
lines, out, in_param = body.splitlines(), [], False
for line in lines:
    if line.strip().startswith("param("):
        in_param = True
        out.append(f"$SiteId = {site_id}  # injected by enable-nested-hyperv")
        continue
    if in_param:
        if line.strip() == ")":
            in_param = False
        continue
    out.append(line)
ps = "\n".join(out)
for i in range(3):
    try:
        s = winrm.Session(f"http://{guest}:5985/wsman", auth=("Administrator", password),
                          transport="ntlm", server_cert_validation="ignore",
                          read_timeout_sec=900, operation_timeout_sec=800)
        r = s.run_ps(ps)
        print(r.std_out.decode())
        print(r.std_err.decode())
        sys.exit(r.status_code)
    except Exception as e:
        print(f"retry {i}: {e}")
        time.sleep(15)
sys.exit(1)
PY
  sleep 10
done

sleep 90
log "PHASE=NESTED_HV_OK guest=${GUEST_IP} (verify vmms after reboot if scheduled)"
