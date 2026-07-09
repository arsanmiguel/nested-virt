#!/usr/bin/env bash
# Boot Win2022.iso recovery to disable hypervisorlaunchtype after nested Hyper-V hang.
set -euo pipefail

VM_NAME="${VM_NAME:-win-hv-nested}"
TIMING_LOG=/var/log/amazon/launch-timing.log

log() { echo "$(date -Iseconds) RECOVER_HV $*" | tee -a "$TIMING_LOG"; }

pkill -f deploy-real-l2.sh 2>/dev/null || true

WIN_ISO="${WIN_ISO:-/var/lib/libvirt/images/Win2022.iso}"

boot_iso_first() {
  local xml="/tmp/${VM_NAME}-iso-boot.xml"
  virsh destroy "$VM_NAME" 2>/dev/null || true
  virsh dumpxml "$VM_NAME" > "$xml"
  python3 - "$xml" "$WIN_ISO" <<'PY'
import sys, re
path, win_iso = sys.argv[1:3]
text = open(path).read()
text = re.sub(r"\s*<boot dev='[^']+'/>", "", text)
text = re.sub(r"\s*<boot order='[^']*'/>", "", text)
text = re.sub(r" bootindex='[^']*'", "", text)
text = re.sub(r"\s*<disk type='file' device='floppy'>.*?</disk>", "", text, flags=re.DOTALL)
text = re.sub(
    r"\s*<disk type='file' device='cdrom'>.*?virtio-win\.iso.*?</disk>",
    "",
    text,
    flags=re.DOTALL,
)
if "Win2022.iso" not in text:
    insert = f"""
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='{win_iso}'/>
      <target dev='sdb' bus='sata'/>
      <readonly/>
      <boot order='1'/>
    </disk>"""
    text = text.replace("</devices>", insert + "\n  </devices>", 1)
else:
    text = re.sub(
        r"(<disk type='file' device='cdrom'>.*?Win2022\.iso.*?</disk>)",
        lambda m: re.sub(
            r"(<target dev='[^']+' bus='[^']+'/>)",
            r"\1\n      <boot order='1'/>",
            m.group(1),
            count=1,
        ),
        text,
        count=1,
        flags=re.DOTALL,
    )
text = re.sub(
    r"(<disk type='file' device='disk'>.*?<target dev='[^']+' bus='[^']+'/>)",
    r"\1\n      <boot order='2'/>",
    text,
    count=1,
    flags=re.DOTALL,
)
open(path, "w").write(text)
PY
  virsh define "$xml"
  virsh start "$VM_NAME"
  log "PHASE=ISO_RECOVERY_BOOT vm=${VM_NAME} vnc=5900"
  log "VNC: Repair your computer -> Troubleshoot -> Command Prompt"
  log "Run: bcdedit /set {current} hypervisorlaunchtype off"
  log "Then: wpeutil shutdown"
}

restore_hd_boot() {
  local xml="/tmp/${VM_NAME}-hd-boot.xml"
  virsh destroy "$VM_NAME" 2>/dev/null || true
  virsh dumpxml "$VM_NAME" > "$xml"
  python3 - "$xml" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"\s*<boot dev='[^']+'/>", "", text)
text = re.sub(r"\s*<boot order='[^']*'/>", "", text)
text = re.sub(r" bootindex='[^']*'", "", text)
text = re.sub(
    r"(<disk type='file' device='disk'>.*?<target dev='[^']+' bus='[^']+'/>)",
    r"\1\n      <boot order='1'/>",
    text,
    count=1,
    flags=re.DOTALL,
)
text = re.sub(
    r"(<disk type='file' device='cdrom'>.*?<target dev='[^']+' bus='[^']+'/>)",
    r"\1\n      <boot order='2'/>",
    text,
    count=1,
    flags=re.DOTALL,
)
open(path, "w").write(text)
PY
  virsh define "$xml"
  virsh start "$VM_NAME"
  log "PHASE=HD_BOOT_RESTORED vm=${VM_NAME}"
}

case "${1:-iso}" in
  iso) boot_iso_first ;;
  hd) restore_hd_boot ;;
  *) echo "usage: $0 [iso|hd]"; exit 1 ;;
esac
