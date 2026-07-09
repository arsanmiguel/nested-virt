#!/usr/bin/env bash
# Full nested L2 bring-up on one metal host: fix KVM XML → vmms → destroy metal inner → Hyper-V Ubuntu.
set -euo pipefail

SITE_ID="${1:-0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${STATE_DIR:-/var/lib/nested-virt}"
PASS_FILE="${PASS_FILE:-${STATE_DIR}/win-guest-admin-password}"
TIMING_LOG=/var/log/amazon/launch-timing.log
VM_WIN="${VM_NAME:-win-hv-nested}"
VM_METAL_INNER="${VM_METAL_INNER:-ubuntu-inner}"

GUEST_IP="10.${SITE_ID}.1.10"
INNER_IP="10.${SITE_ID}.1.20"

log() { echo "$(date -Iseconds) REAL_L2 $*" | tee -a "$TIMING_LOG"; }

if [[ -f /tmp/ensure-lab-dnsmasq.sh ]]; then
  # shellcheck source=/dev/null
  source /tmp/ensure-lab-dnsmasq.sh
  harden_metal_dns || true
fi

wait_guest_ping() {
  local ip="$1" tries="${2:-60}"
  for _ in $(seq 1 "$tries"); do
    if ping -c1 -W2 "$ip" >/dev/null 2>&1; then return 0; fi
    sleep 10
  done
  return 1
}

wait_winrm() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y python3-pip >/dev/null 2>&1 || true
  pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true
  python3 - "$GUEST_IP" "$PASS_FILE" <<'PY'
import sys, time, winrm
guest, pw = sys.argv[1:3]
password = open(pw).read().strip()
for i in range(48):
    try:
        s = winrm.Session(f"http://{guest}:5985/wsman", auth=("Administrator", password),
                          transport="ntlm", server_cert_validation="ignore", read_timeout_sec=30)
        s.run_cmd("cmd.exe", ["/c", "echo ok"])
        print("winrm ok")
        sys.exit(0)
    except Exception as e:
        print(f"retry {i}: {e}")
        time.sleep(10)
sys.exit(1)
PY
}

run_ps_on_guest() {
  local ps_file="$1"
  python3 - "$GUEST_IP" "$PASS_FILE" "$ps_file" "$SITE_ID" <<'PY'
import sys, winrm
guest, pw, ps_path, site_id = sys.argv[1:5]
password = open(pw).read().strip()
body = open(ps_path).read()
# Inline script for WinRM — never reference Linux paths inside the Windows guest.
lines, out, in_param = body.splitlines(), [], False
for line in lines:
    if line.strip().startswith("param("):
        in_param = True
        out.append(f"$SiteId = {site_id}  # injected by deploy-real-l2")
        continue
    if in_param:
        if line.strip() == ")":
            in_param = False
        continue
    out.append(line)
ps = "\n".join(out)
s = winrm.Session(f"http://{guest}:5985/wsman", auth=("Administrator", password),
                  transport="ntlm", server_cert_validation="ignore",
                  read_timeout_sec=900, operation_timeout_sec=800)
r = s.run_ps(ps)
sys.stdout.write(r.std_out.decode(errors="replace"))
sys.stderr.write(r.std_err.decode(errors="replace"))
if r.status_code:
    sys.exit(r.status_code)
PY
}

check_vmms() {
  python3 - "$GUEST_IP" "$PASS_FILE" <<'PY'
import sys, winrm
guest, pw = sys.argv[1:3]
password = open(pw).read().strip()
s = winrm.Session(f"http://{guest}:5985/wsman", auth=("Administrator", password),
                  transport="ntlm", server_cert_validation="ignore")
r = s.run_cmd("sc.exe", ["query", "vmms"])
out = r.std_out.decode()
print(out)
if "RUNNING" not in out:
    sys.exit(1)
print("PHASE=VMMS_RUNNING")
PY
}

destroy_metal_inner() {
  if virsh dominfo "$VM_METAL_INNER" >/dev/null 2>&1; then
    log "destroy metal KVM shortcut VM ${VM_METAL_INNER}"
    virsh destroy "$VM_METAL_INNER" 2>/dev/null || true
    virsh undefine "$VM_METAL_INNER" --nvram 2>/dev/null || true
  fi
}

main() {
  log "begin site=${SITE_ID} guest=${GUEST_IP} inner=${INNER_IP}"

  log "step 1: fix KVM nested XML for ${VM_WIN}"
  "${SCRIPT_DIR}/fix-kvm-nested-hyperv-xml.sh"

  log "step 2: wait Windows guest ${GUEST_IP}"
  wait_guest_ping "$GUEST_IP" 40 || { log "ERROR guest not pingable"; exit 1; }
  wait_winrm || { log "ERROR winrm not ready"; exit 1; }

  log "step 3: enable Hyper-V hypervisor inside Windows"
  run_ps_on_guest "${SCRIPT_DIR}/enable-hyperv-nested-host.ps1" || true

  log "step 4: wait for possible reboot + vmms (up to 20 min)"
  sleep 120
  wait_guest_ping "$GUEST_IP" 90 || { log "ERROR guest down after hyperv enable"; exit 1; }
  wait_winrm || { log "ERROR winrm after reboot"; exit 1; }

  if ! check_vmms; then
    log "vmms not running — retry enable after reboot"
    run_ps_on_guest "${SCRIPT_DIR}/enable-hyperv-nested-host.ps1"
    sleep 90
    wait_guest_ping "$GUEST_IP" 48
    wait_winrm
    check_vmms || { log "ERROR vmms still not RUNNING"; exit 1; }
  fi

  log "step 5: remove metal KVM inner VM (wrong L2 path)"
  destroy_metal_inner

  log "step 6: provision Ubuntu on Hyper-V"
  export SITE_ID FORCE_REINSTALL=1 PS1_SRC="${SCRIPT_DIR}/provision-ubuntu-inner-vm.ps1"
  "${SCRIPT_DIR}/deploy-inner-ubuntu-on-host.sh"

  log "step 6b: lab DNS on Windows + inner internet"
  run_ps_on_guest "${SCRIPT_DIR}/ensure-lab-guest-dns.ps1" || true
  "${SCRIPT_DIR}/ensure-inner-guest-dns.sh" "$SITE_ID" || true

  log "step 7: wait inner ${INNER_IP}"
  for _ in $(seq 1 36); do
    ping -c1 -W2 "$INNER_IP" >/dev/null 2>&1 && { log "PHASE=REAL_L2_OK ip=${INNER_IP}"; exit 0; }
    sleep 10
  done
  log "PHASE=REAL_L2_FAIL ip=${INNER_IP}"
  exit 1
}

main "$@"
