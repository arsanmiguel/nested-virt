#!/usr/bin/env bash
# Provision Ubuntu 26.04 inner VM on metal KVM (L2 on br-default).
set -euo pipefail

SITE_ID="${1:-0}"
STATE_DIR="${STATE_DIR:-/var/lib/nested-virt}"
VM_NAME="${VM_NAME:-ubuntu-inner}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-26.04}"
TIMING_LOG=/var/log/amazon/launch-timing.log

INNER_IP="10.${SITE_ID}.1.20"
WIN_IP="10.${SITE_ID}.1.10"
GATEWAY="10.${SITE_ID}.1.1"
INNER_MAC="$(printf '52:54:00:20:%02x:20' "$((10#${SITE_ID}))")"
WIN_MAC="$(printf '52:54:00:10:%02x:10' "$((10#${SITE_ID}))")"
DISK="${STATE_DIR}/images/${VM_NAME}.qcow2"
BASE_QCOW="${STATE_DIR}/ubuntu-${UBUNTU_RELEASE}-inner-base.qcow2"

log() { echo "$(date -Iseconds) INNER_KVM $*" | tee -a "$TIMING_LOG"; }

ensure_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y qemu-utils curl virtinst dnsmasq guestfs-tools >/dev/null
}

ensure_base_qcow() {
  if [[ -f "$BASE_QCOW" ]]; then
    log "reuse ${BASE_QCOW}"
    return 0
  fi
  local img="${STATE_DIR}/ubuntu-${UBUNTU_RELEASE}-cloudimg.img"
  local url="${UBUNTU_CLOUD_IMG_URL:-https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release/ubuntu-${UBUNTU_RELEASE}-server-cloudimg-amd64.img}"
  log "fetch ${url}"
  curl -fsSL "$url" -o "$img"
  qemu-img resize "$img" 20G
  mv "$img" "$BASE_QCOW"
  log "created ${BASE_QCOW}"
}

write_lab_dnsmasq() {
  local conf=/etc/nested-virt-dnsmasq.conf
  cat > "$conf" <<EOF
port=0
interface=br-default
bind-interfaces
dhcp-host=${WIN_MAC},${WIN_IP},set:nested-guest,infinite
dhcp-option=tag:nested-guest,3,${GATEWAY}
dhcp-option=tag:nested-guest,6,${GATEWAY}
dhcp-host=${INNER_MAC},${INNER_IP},set:inner,infinite
dhcp-option=tag:inner,3,${GATEWAY}
dhcp-option=tag:inner,6,${GATEWAY}
EOF
  pkill -f "${conf}" 2>/dev/null || true
  sleep 1
  nohup dnsmasq -C "$conf" --pid-file=/run/nested-virt-dnsmasq.pid \
    >> /var/log/nested-virt-inner-deploy.log 2>&1 &
  ip link set br-default up 2>/dev/null || true
  log "dnsmasq lab win=${WIN_IP} inner=${INNER_IP}"
}

customize_disk() {
  local netplan="/etc/netplan/99-nested-virt.yaml"
  log "virt-customize ${DISK} ip=${INNER_IP} mac=${INNER_MAC}"
  virt-customize -a "$DISK" \
    --run-command 'cloud-init clean --logs 2>/dev/null || rm -rf /var/lib/cloud/instances /var/lib/cloud/instance /var/lib/cloud/data/* 2>/dev/null; sync' \
    --write "${netplan}:network:
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
          - ${GATEWAY}
" \
    --run-command "chmod 600 ${netplan}" \
    --run-command 'echo ubuntu:ubuntu | chpasswd; useradd -m -s /bin/bash -G sudo ubuntu 2>/dev/null || true; echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu; chmod 440 /etc/sudoers.d/ubuntu' \
    --hostname "ubuntu-inner-s${SITE_ID}"
}

destroy_vm() {
  if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
  fi
  rm -f "$DISK"
}

start_vm() {
  mkdir -p "${STATE_DIR}/images"
  virsh net-destroy default 2>/dev/null || true
  log "copy base disk -> ${DISK}"
  qemu-img convert -O qcow2 "$BASE_QCOW" "$DISK"
  customize_disk
  log "virt-install ${VM_NAME} ip=${INNER_IP} mac=${INNER_MAC}"
  virt-install \
    --name "$VM_NAME" \
    --memory 3072 \
    --vcpus 2 \
    --cpu host-passthrough \
    --disk path="$DISK",format=qcow2,bus=virtio \
    --network "bridge=br-default,model=virtio,mac=${INNER_MAC}" \
    --os-variant ubuntu24.04 \
    --graphics none \
    --import \
    --noautoconsole \
    --boot hd,menu=off
}

main() {
  ensure_tools
  ensure_base_qcow
  write_lab_dnsmasq
  destroy_vm
  start_vm
  log "wait for ${INNER_IP}"
  for _ in $(seq 1 36); do
    ping -c1 -W2 "$INNER_IP" >/dev/null 2>&1 && { log "PHASE=INNER_UBUNTU_OK ip=${INNER_IP}"; exit 0; }
    sleep 10
  done
  log "PHASE=INNER_UBUNTU_FAIL ip=${INNER_IP}"
  exit 1
}

main "$@"
