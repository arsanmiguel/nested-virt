#!/usr/bin/env bash
# Patch win-hv-nested libvirt XML for nested Hyper-V inside KVM.
# host-passthrough exposes the CPU hypervisor flag and causes a boot hang once
# Windows sets hypervisorlaunchtype auto — use a pinned model with hypervisor disabled.
set -euo pipefail

VM_NAME="${VM_NAME:-win-hv-nested}"
TIMING_LOG=/var/log/amazon/launch-timing.log

log() { echo "$(date -Iseconds) FIX_KVM_NESTED $*" | tee -a "$TIMING_LOG"; }

NESTED_CPU_MODEL="${NESTED_CPU_MODEL:-Cascadelake-Server-noTSX}"
NESTED_CPU_XML="<cpu mode='custom' match='exact' check='partial'>
    <model fallback='allow'>${NESTED_CPU_MODEL}</model>
    <feature policy='disable' name='hypervisor'/>
    <feature policy='require' name='vmx'/>
    <feature policy='require' name='pdpe1gb'/>
  </cpu>"

patch_xml() {
  local xml="/tmp/${VM_NAME}-nested-fix.xml"
  virsh dumpxml "$VM_NAME" > "$xml"
  python3 - "$xml" "$NESTED_CPU_XML" <<'PY'
import sys, re
path, nested_cpu = sys.argv[1:3]
text = open(path).read()

text = re.sub(r"<cpu[^>]*>.*?</cpu>", nested_cpu, text, count=1, flags=re.DOTALL)

if "<kvm>" not in text and "<features>" in text:
    text = text.replace(
        "<features>",
        "<features>\n    <kvm>\n      <hidden state='on'/>\n    </kvm>",
        1,
    )
elif "<kvm>" in text and "hidden state='on'" not in text:
    text = re.sub(r"<kvm>\s*</kvm>", "<kvm>\n      <hidden state='on'/>\n    </kvm>", text, count=1)

# Do not inject partial hyperv enlightenments — synic without vpindex prevents QEMU start.
text = re.sub(r"\s*<hyperv mode='custom'>.*?</hyperv>", "", text, flags=re.DOTALL)
text = re.sub(r"\s*<hyperv>.*?</hyperv>", "", text, flags=re.DOTALL)
text = re.sub(r"\s*<hyperv/>", "", text)
text = text.replace("<timer name='hypervclock' present='yes'/>", "<timer name='hypervclock' present='no'/>")

open(path, "w").write(text)
PY
  log "redefine ${VM_NAME} (${NESTED_CPU_MODEL} vmx + hypervisor disabled + kvm hidden)"
  local was_running=0
  if virsh domstate "$VM_NAME" 2>/dev/null | grep -q running; then
    was_running=1
    virsh destroy "$VM_NAME"
  fi
  virsh define "$xml"
  if [[ "$was_running" == "1" ]]; then
    virsh start "$VM_NAME"
    log "restarted ${VM_NAME} — Windows guest will reboot; wait for WinRM"
  fi
  log "PHASE=KVM_NESTED_XML_OK vm=${VM_NAME}"
}

verify_xml() {
  log "verify:"
  virsh dumpxml "$VM_NAME" | grep -E "Skylake|hypervisor|vmx|synic|kvm hidden|hypervclock" || true
}

main() {
  virsh dominfo "$VM_NAME" >/dev/null 2>&1 || { log "ERROR no domain ${VM_NAME}"; exit 1; }
  patch_xml
  verify_xml
}

main "$@"
