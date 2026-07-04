#!/usr/bin/env bash
# Ensure L2 inner Ubuntu uses public DNS and can reach the internet (SSH from metal host).
set -euo pipefail

SITE_ID="${1:-0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${STATE_DIR:-/var/lib/nested-virt}"
PASS_FILE="${PASS_FILE:-${STATE_DIR}/win-guest-admin-password}"
TIMING_LOG=/var/log/amazon/launch-timing.log
INNER_IP="10.${SITE_ID}.1.20"
GATEWAY="10.${SITE_ID}.1.1"
INNER_MAC="$(printf '52:54:00:20:%02x:20' "$((10#${SITE_ID}))")"
INNER_USER="${INNER_SSH_USER:-ubuntu}"
INNER_PASS="${INNER_SSH_PASS:-ubuntu}"

log() { echo "$(date -Iseconds) INNER_DNS $*" | tee -a "$TIMING_LOG"; }

apply_win_dns() {
  local guest_ip="10.${SITE_ID}.1.10"
  [[ -f "$PASS_FILE" ]] || { log "WARN skip win dns — no ${PASS_FILE}"; return 0; }
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y python3-pip >/dev/null 2>&1 || true
  pip3 install -q pywinrm 2>/dev/null || pip3 install --break-system-packages -q pywinrm 2>/dev/null || true
  local ps1="${STATE_DIR}/ensure-lab-guest-dns.ps1"
  [[ -f /tmp/ensure-lab-guest-dns.ps1 ]] && ps1="/tmp/ensure-lab-guest-dns.ps1"
  [[ -f "$ps1" ]] || { log "WARN ensure-lab-guest-dns.ps1 missing"; return 0; }
  python3 - "$guest_ip" "$PASS_FILE" "$ps1" "$SITE_ID" <<'PY'
import sys, winrm
guest, pw, ps_path, site_id = sys.argv[1:5]
password = open(pw).read().strip()
body = open(ps_path).read()
lines, out, in_param = [], [], False
for line in body.splitlines():
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
                  transport="ntlm", server_cert_validation="ignore", read_timeout_sec=120)
r = s.run_ps(ps)
sys.stdout.write(r.std_out.decode(errors="replace"))
sys.stderr.write(r.std_err.decode(errors="replace"))
sys.exit(r.status_code or 0)
PY
}

inner_internet_ok() {
  local out
  out=$(sshpass -p "$INNER_PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 "${INNER_USER}@${INNER_IP}" \
    'curl -sf --connect-timeout 10 https://checkip.amazonaws.com && echo INNER_INTERNET_OK' 2>/dev/null || true)
  echo "$out" | grep -q INNER_INTERNET_OK
}

patch_inner_netplan() {
  sshpass -p "$INNER_PASS" ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=15 "${INNER_USER}@${INNER_IP}" "sudo bash -s" <<EOF
set -e
cat > /etc/netplan/99-nested-virt-lab.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    lab0:
      match:
        macaddress: ${INNER_MAC}
      dhcp4: false
      addresses:
        - ${INNER_IP}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - 1.1.1.1
          - 1.0.0.1
NETPLAN
chmod 600 /etc/netplan/99-nested-virt-lab.yaml
netplan apply
EOF
}

refresh_inner_vhdx() {
  local prep deploy ps1
  prep="${SCRIPT_DIR}/prepare-ubuntu-inner-image.sh"
  deploy="${SCRIPT_DIR}/deploy-inner-ubuntu-on-host.sh"
  ps1="${SCRIPT_DIR}/provision-ubuntu-inner-vm.ps1"
  [[ -f /tmp/prepare-ubuntu-inner-image.sh ]] && prep="/tmp/prepare-ubuntu-inner-image.sh"
  [[ -f /tmp/deploy-inner-ubuntu-on-host.sh ]] && deploy="/tmp/deploy-inner-ubuntu-on-host.sh"
  [[ -f /tmp/provision-ubuntu-inner-vm.ps1 ]] && ps1="/tmp/provision-ubuntu-inner-vm.ps1"
  log "refresh inner VHDX from metal (SSH patch unavailable)"
  "$prep" "$SITE_ID" || return 1
  export SITE_ID FORCE_REINSTALL=1 PS1_SRC="$ps1"
  FORCE_REINSTALL=1 "$deploy"
}

main() {
  log "begin site=${SITE_ID} inner=${INNER_IP}"
  apply_win_dns || true

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y sshpass openssh-client curl >/dev/null 2>&1 || true

  if ! ping -c1 -W3 "$INNER_IP" >/dev/null 2>&1; then
    if [[ "${REFRESH_INNER_VHDX:-0}" == "1" ]]; then
      log "inner ${INNER_IP} not pingable — VHDX refresh"
      refresh_inner_vhdx && inner_internet_ok && {
        log "PHASE=INNER_INTERNET_OK ip=${INNER_IP} (vhdx refresh)"
        exit 0
      }
      log "WARN inner refresh did not restore ${INNER_IP}"
      exit 1
    fi
    log "WARN inner ${INNER_IP} not pingable — skip inner DNS patch"
    exit 0
  fi

  if inner_internet_ok; then
    log "PHASE=INNER_INTERNET_OK ip=${INNER_IP} (existing)"
    exit 0
  fi

  log "patch inner netplan DNS on ${INNER_IP} (ssh)"
  if patch_inner_netplan 2>/dev/null && inner_internet_ok; then
    log "PHASE=INNER_INTERNET_OK ip=${INNER_IP} (patched)"
    exit 0
  fi

  if [[ "${REFRESH_INNER_VHDX:-0}" == "1" ]]; then
    refresh_inner_vhdx && inner_internet_ok && {
      log "PHASE=INNER_INTERNET_OK ip=${INNER_IP} (vhdx refresh)"
      exit 0
    }
  fi

  log "WARN inner internet not verified — set REFRESH_INNER_VHDX=1 and re-run"
  exit 1
}

main "$@"
