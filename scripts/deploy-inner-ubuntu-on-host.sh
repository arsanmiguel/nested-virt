#!/usr/bin/env bash
# Deploy Ubuntu inner Hyper-V VM on this metal host (prepare image + WinRM to Windows guest).
set -euo pipefail

TIMING_LOG=/var/log/amazon/launch-timing.log
STATE_DIR="${STATE_DIR:-/var/lib/nested-virt}"
PASS_FILE="${PASS_FILE:-${STATE_DIR}/win-guest-admin-password}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "$(date -Iseconds) DEPLOY_INNER $*" | tee -a "$TIMING_LOG"; }

imds_token() {
  curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}
imds_tag() {
  local key="$1" token
  token="$(imds_token)"
  curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/tags/instance/${key}" 2>/dev/null
}

SITE_ID="${SITE_ID:-$(imds_tag SiteId || echo 0)}"
GUEST_IP="10.${SITE_ID}.1.10"
METAL_GW="10.${SITE_ID}.1.1"
INNER_IP="10.${SITE_ID}.1.20"
VM_MAC="$(printf '52540020%02x20' "$((10#${SITE_ID}))")"
SERVE_DIR="${STATE_DIR}/inner-ubuntu-serve"
PS1_SRC="${PS1_SRC:-${SCRIPT_DIR}/provision-ubuntu-inner-vm.ps1}"
[[ -f "$PS1_SRC" ]] || PS1_SRC="/tmp/provision-ubuntu-inner-vm.ps1"
export PS1_SRC
HTTP_PORT="${INNER_HTTP_PORT:-8090}"
FORCE="${FORCE_REINSTALL:-0}"

[[ -f "$PASS_FILE" ]] || { log "missing ${PASS_FILE}"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get install -y python3-pip curl qemu-utils genisoimage >/dev/null 2>&1 || true
pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true

"${SCRIPT_DIR}/prepare-ubuntu-inner-image.sh" "$SITE_ID"
cp "$PS1_SRC" "${SERVE_DIR}/provision-ubuntu-inner-vm.ps1"
log "staged ps1 ${SERVE_DIR}/provision-ubuntu-inner-vm.ps1"
nohup python3 -m http.server "$HTTP_PORT" --bind "$METAL_GW" --directory "$SERVE_DIR" \
  >> /var/log/nested-virt-inner-http.log 2>&1 &
HTTP_PID=$!
sleep 1

VHDX_URL="http://${METAL_GW}:${HTTP_PORT}/ubuntu-inner.vhdx"
SEED_URL="http://${METAL_GW}:${HTTP_PORT}/ubuntu-inner-seed.iso"
PS1_URL="http://${METAL_GW}:${HTTP_PORT}/provision-ubuntu-inner-vm.ps1"

cleanup() { kill "$HTTP_PID" 2>/dev/null || true; }
trap cleanup EXIT

log "winrm provision guest=${GUEST_IP} inner=${INNER_IP}"
python3 - "$GUEST_IP" "$PASS_FILE" "$SITE_ID" "$METAL_GW" "$VHDX_URL" "$SEED_URL" "$PS1_URL" "$INNER_IP" "$VM_MAC" "$FORCE" <<'PY'
import sys
import winrm

guest, pass_file, site_id, metal_gw, vhdx_url, seed_url, ps1_url, inner_ip, vm_mac, force = sys.argv[1:11]
password = open(pass_file).read().strip()
force_flag = "-ForceReinstall" if force == "1" else ""
ps = f"""
$ErrorActionPreference = 'Stop'
$StateDir = 'C:\\ProgramData\\nested-virt'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Invoke-WebRequest -Uri '{ps1_url}' -OutFile (Join-Path $StateDir 'provision-inner.ps1') -UseBasicParsing
& (Join-Path $StateDir 'provision-inner.ps1') -SiteId {site_id} -MetalGateway '{metal_gw}' -VhdxUrl '{vhdx_url}' -SeedUrl '{seed_url}' -InnerIp '{inner_ip}' -VmMac '{vm_mac}' {force_flag}
"""
s = winrm.Session(
    f"http://{guest}:5985/wsman",
    auth=("Administrator", password),
    transport="ntlm",
    server_cert_validation="ignore",
    read_timeout_sec=7200,
    operation_timeout_sec=7000,
)
r = s.run_ps(ps)
out = r.std_out.decode(errors="replace")
err = r.std_err.decode(errors="replace")
sys.stdout.write(out)
sys.stderr.write(err)
if r.status_code:
    sys.exit(r.status_code)
PY

log "wait for inner ping ${INNER_IP}"
for _ in $(seq 1 36); do
  if ping -c1 -W2 "$INNER_IP" >/dev/null 2>&1; then
    log "PHASE=INNER_UBUNTU_OK ip=${INNER_IP}"
    exit 0
  fi
  sleep 10
done
log "PHASE=INNER_UBUNTU_FAIL ip=${INNER_IP} timeout"
exit 1
