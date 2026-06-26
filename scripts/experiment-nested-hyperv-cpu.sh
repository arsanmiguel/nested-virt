#!/usr/bin/env bash
# Experiment: nested Hyper-V boot with a specific libvirt CPU model on 8488C metal.
# Usage: experiment-nested-hyperv-cpu.sh <site-id> [cpu-model]
# Logs: /var/log/nested-virt-experiment.log and launch-timing.log
set -euo pipefail

SITE_ID="${1:?usage: experiment-nested-hyperv-cpu.sh <site-id> [cpu-model]}"
CPU_MODEL="${2:-Cascadelake-Server-noTSX}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_NAME="${VM_NAME:-win-hv-nested}"
PASS_FILE="${PASS_FILE:-/var/lib/nested-virt/win-guest-admin-password}"
TIMING_LOG=/var/log/amazon/launch-timing.log
EXP_LOG=/var/log/nested-virt-experiment.log
GUEST_IP="10.${SITE_ID}.1.10"

log() { echo "$(date -Iseconds) EXP_CPU model=${CPU_MODEL} $*" | tee -a "$TIMING_LOG" | tee -a "$EXP_LOG"; }

wait_ping() {
  local ip="$1" tries="${2:-60}"
  for _ in $(seq 1 "$tries"); do
    ping -c1 -W2 "$ip" >/dev/null 2>&1 && return 0
    sleep 10
  done
  return 1
}

wait_winrm() {
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

run_ps_file() {
  local ps_file="$1"
  python3 - "$GUEST_IP" "$PASS_FILE" "$ps_file" "$SITE_ID" <<'PY'
import sys, winrm
guest, pw, ps_path, site_id = sys.argv[1:5]
password = open(pw).read().strip()
body = open(ps_path).read()
lines, out, in_param = body.splitlines(), [], False
for line in lines:
    if line.strip().startswith("param("):
        in_param = True
        out.append(f"$SiteId = {site_id}")
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
sys.exit(0 if "RUNNING" in out else 1)
PY
}

patch_cpu() {
  local xml="/tmp/${VM_NAME}-exp-${CPU_MODEL}.xml"
  local cpu_xml
  cpu_xml="<cpu mode='custom' match='exact' check='partial'>
    <model fallback='allow'>${CPU_MODEL}</model>
    <feature policy='disable' name='hypervisor'/>
    <feature policy='require' name='vmx'/>
    <feature policy='require' name='pdpe1gb'/>
  </cpu>"
  virsh dumpxml "$VM_NAME" > "$xml"
  python3 - "$xml" "$cpu_xml" <<'PY'
import sys, re
path, nested_cpu = sys.argv[1:3]
text = open(path).read()
text = re.sub(r"<cpu[^>]*>.*?</cpu>", nested_cpu, text, count=1, flags=re.DOTALL)
if "<kvm>" not in text and "<features>" in text:
    text = text.replace("<features>", "<features>\n    <kvm>\n      <hidden state='on'/>\n    </kvm>", 1)
text = re.sub(r"\s*<hyperv mode='custom'>.*?</hyperv>", "", text, flags=re.DOTALL)
text = re.sub(r"\s*<hyperv>.*?</hyperv>", "", text, flags=re.DOTALL)
text = re.sub(r"\s*<hyperv/>", "", text)
text = text.replace("<timer name='hypervclock' present='yes'/>", "<timer name='hypervclock' present='no'/>")
open(path, "w").write(text)
PY
  local was_running=0
  if virsh domstate "$VM_NAME" 2>/dev/null | grep -q running; then
    was_running=1
    virsh destroy "$VM_NAME"
  fi
  virsh define "$xml"
  if [[ "$was_running" == "1" ]] || [[ "${START_VM:-1}" == "1" ]]; then
    virsh start "$VM_NAME"
  fi
  log "patched cpu model=${CPU_MODEL}"
  virsh dumpxml "$VM_NAME" | grep -E "model fallback|hypervisor|vmx" | head -5 | tee -a "$EXP_LOG"
}

main() {
  pkill -f enable-nested-hyperv.sh 2>/dev/null || true
  pkill -f deploy-real-l2.sh 2>/dev/null || true

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y python3-pip >/dev/null 2>&1 || true
  pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true

  log "begin site=${SITE_ID} guest=${GUEST_IP} experiment=cpu_model"

  log "step 1: patch libvirt CPU and reboot guest"
  patch_cpu
  wait_ping "$GUEST_IP" 48 || { log "ERROR guest down after CPU patch"; exit 1; }
  wait_winrm || { log "ERROR winrm down after CPU patch"; exit 1; }
  log "step 1 ok — desktop reachable with new CPU"

  log "step 2: enable Hyper-V hypervisor (scheduled reboot)"
  run_ps_file "${SCRIPT_DIR}/enable-hyperv-nested-host.ps1" | tee -a "$EXP_LOG" || true

  log "step 3: wait for hypervisor reboot (up to 20 min)"
  sleep 120
  wait_ping "$GUEST_IP" 90 || { log "PHASE=EXPERIMENT_FAIL reason=guest_down_after_hyperv_reboot model=${CPU_MODEL}"; exit 1; }
  wait_winrm || { log "PHASE=EXPERIMENT_FAIL reason=winrm_down_after_hyperv_reboot model=${CPU_MODEL}"; exit 1; }

  if check_vmms | tee -a "$EXP_LOG"; then
    log "PHASE=EXPERIMENT_OK model=${CPU_MODEL} vmms=RUNNING"
    exit 0
  fi

  log "PHASE=EXPERIMENT_FAIL reason=vmms_not_running model=${CPU_MODEL}"
  exit 1
}

main "$@"
