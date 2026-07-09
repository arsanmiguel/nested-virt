#!/usr/bin/env bash
# Lab VNC: libvirt guest console on 127.0.0.1 only (SSH tunnel from laptop).
# Never bind VNC to 0.0.0.0 (e.g. virt-install --graphics vnc,listen=0.0.0.0).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

LAB_VNC_LISTEN="${LAB_VNC_LISTEN:-127.0.0.1}"
LAB_VNC_PORT="${LAB_VNC_PORT:-5900}"

# Patch running libvirt domains: graphics listen must be loopback-only.
harden_metal_vnc() {
  command -v virsh >/dev/null 2>&1 || return 0
  local vm xml running
  for vm in $(virsh list --all --name 2>/dev/null); do
    if [[ -z "$vm" ]]; then continue; fi
    xml="/tmp/${vm}-vnc-harden.xml"
    virsh dumpxml "$vm" > "$xml"
    if ! grep -q "<graphics type='vnc'" "$xml" && ! grep -q '<graphics type="vnc"' "$xml"; then
      continue
    fi
    if grep -qE "listen='127\.0\.0\.1'|listen=\"127\.0\.0\.1\"" "$xml"; then
      continue
    fi
    python3 - "$xml" "$LAB_VNC_LISTEN" <<'PY'
import re, sys
path, listen = sys.argv[1:3]
text = open(path).read()
if re.search(r"listen='0\.0\.0\.0'", text) or re.search(r'listen="0\.0\.0\.0"', text):
    text = re.sub(r"listen='0\.0\.0\.0'", f"listen='{listen}'", text)
    text = re.sub(r'listen="0\.0\.0\.0"', f'listen="{listen}"', text)
elif re.search(r"<graphics type='vnc'[^>]*>", text) and "listen=" not in re.search(r"<graphics type='vnc'[^>]*>", text).group(0):
    text = re.sub(r"(<graphics type='vnc')", rf"\1 listen='{listen}'", text, count=1)
open(path, "w").write(text)
PY
    running=0
    virsh domstate "$vm" 2>/dev/null | grep -q running && running=1
    if [[ "$running" -eq 1 ]]; then
      virsh destroy "$vm" 2>/dev/null || true
    fi
    virsh define "$xml"
    if [[ "$running" -eq 1 ]]; then
      virsh start "$vm"
    fi
    echo "hardened VNC listen=${LAB_VNC_LISTEN} vm=${vm}"
  done
}

# Exit 0 if no VNC/RFB listener on non-loopback.
verify_no_public_vnc() {
  local line
  while read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    if echo "$line" | grep -qE '127\.0\.0\.1:59[0-9]{2}|\[::1\]:59[0-9]{2}'; then
      continue
    fi
    if echo "$line" | grep -qE ':59[0-9]{2}|\*:5900|0\.0\.0\.0:59'; then
      echo "FAIL: VNC listener: $line"
      return 1
    fi
  done < <(ss -tlnp 2>/dev/null | grep -E ':59[0-9]{2}' || true)
  echo "OK: no public VNC listeners"
  return 0
}
