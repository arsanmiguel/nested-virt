#!/usr/bin/env bash
# Prepare Ubuntu cloud image (VHDX + nocloud seed) for Hyper-V inner VM on metal host.
set -euo pipefail

SITE_ID="${1:-0}"
STATE_DIR="${STATE_DIR:-/var/lib/nested-virt}"
SERVE_DIR="${SERVE_DIR:-${STATE_DIR}/inner-ubuntu-serve}"
TIMING_LOG=/var/log/amazon/launch-timing.log

UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04}"
IMG_URL="${UBUNTU_CLOUD_IMG_URL:-https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release/ubuntu-${UBUNTU_RELEASE}-server-cloudimg-amd64.img}"
BASE_VHDX="${STATE_DIR}/ubuntu-${UBUNTU_RELEASE}-inner-base.vhdx"
VHDX_OUT="${SERVE_DIR}/ubuntu-inner.vhdx"
SEED_OUT="${SERVE_DIR}/ubuntu-inner-seed.iso"

INNER_IP="10.${SITE_ID}.1.20"
GATEWAY="10.${SITE_ID}.1.1"
LAB_DNS_PRIMARY="1.1.1.1"
LAB_DNS_SECONDARY="1.0.0.1"
INNER_MAC="$(printf '52:54:00:20:%02x:20' "$((10#${SITE_ID}))")"
INNER_PASS_FILE="${INNER_PASS_FILE:-${STATE_DIR}/inner-ubuntu-ssh-password}"
INNER_KEY="${INNER_KEY:-${STATE_DIR}/inner-ubuntu-ssh-key}"
INNER_PUB="${INNER_PUB:-${INNER_KEY}.pub}"

log() { echo "$(date -Iseconds) INNER_UBUNTU $*" | tee -a "$TIMING_LOG"; }

generate_inner_ssh_password() {
  local pw
  pw=$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)
  umask 077
  printf '%s' "$pw" > "$INNER_PASS_FILE"
  chmod 600 "$INNER_PASS_FILE"
  INNER_LAB_PASS="$pw"
  log "generated inner ssh password file ${INNER_PASS_FILE}"
}

ensure_inner_ssh_key() {
  if [[ ! -f "$INNER_KEY" ]]; then
    umask 077
    ssh-keygen -t ed25519 -N "" -f "$INNER_KEY" >/dev/null
    chmod 600 "$INNER_KEY"
    log "generated inner ssh key ${INNER_KEY}"
  fi
}

ensure_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y qemu-utils genisoimage curl libguestfs-tools >/dev/null
}

fetch_and_convert_base() {
  if [[ -f "$BASE_VHDX" ]]; then
    log "reuse base vhdx ${BASE_VHDX}"
    return 0
  fi
  local img="${STATE_DIR}/ubuntu-${UBUNTU_RELEASE}-cloudimg.img"
  log "fetch ${IMG_URL}"
  curl -fsSL "$IMG_URL" -o "$img"
  log "convert qcow2 -> vhdx (${BASE_VHDX})"
  qemu-img resize "$img" 20G
  qemu-img convert -p -f qcow2 -O vhdx -o subformat=dynamic "$img" "$BASE_VHDX"
  rm -f "$img"
}

build_seed_iso() {
  local staging
  staging="$(mktemp -d)"
  cat > "${staging}/meta-data" <<EOF
instance-id: nested-virt-inner-${SITE_ID}-$(date +%s)
local-hostname: ubuntu-inner-s${SITE_ID}
EOF
  cat > "${staging}/user-data" <<EOF
#cloud-config
users:
  - name: ubuntu
    gecos: Ubuntu
    groups: adm,cdrom,dip,lxd,sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
ssh_pwauth: true
chpasswd:
  list: |
    ubuntu:${INNER_LAB_PASS}
  expire: false
package_update: false
packages:
  - qemu-guest-agent
  - iputils-ping
  - curl
  - dnsutils
  - openssh-server
write_files:
  - path: /etc/ssh/sshd_config.d/99-nested-virt-password.conf
    content: |
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      PubkeyAuthentication yes
    permissions: '0644'
runcmd:
  - rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
  - systemctl enable --now qemu-guest-agent || true
  - systemctl restart ssh || true
  - bash -lc 'IF=\$(ip -o link | awk -F": " "/${INNER_MAC}/ {print \$2}" | head -1); [ -n "\$IF" ] && ip link set "\$IF" up && ip addr replace ${INNER_IP}/24 dev "\$IF" && ip route replace default via ${GATEWAY} dev "\$IF" || true'
EOF
  cat > "${staging}/network-config" <<EOF
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
        - ${LAB_DNS_PRIMARY}
        - ${LAB_DNS_SECONDARY}
EOF
  genisoimage -output "$SEED_OUT" -volid cidata -joliet -rock \
    "${staging}/meta-data" "${staging}/user-data" "${staging}/network-config" >/dev/null
  rm -rf "$staging"
  log "seed iso ${SEED_OUT} ip=${INNER_IP} mac=${INNER_MAC}"
}

inject_netplan() {
  local netplan staging pw_line auth_keys
  netplan="$(mktemp)"
  staging="$(mktemp -d)"
  auth_keys="${staging}/authorized_keys"
  cp "$INNER_PUB" "$auth_keys"
  cat > "$netplan" <<EOF
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
          - ${LAB_DNS_PRIMARY}
          - ${LAB_DNS_SECONDARY}
EOF
  # Ubuntu cloud images create the ubuntu user on first boot via cloud-init; bake
  # the account + password offline so SSH works even if nocloud seed is slow/missed.
  printf 'ubuntu:%s\n' "$(openssl passwd -6 "$INNER_LAB_PASS")" > "${staging}/chpasswd_line"
  virt-customize -a "$VHDX_OUT" \
    --upload "${netplan}:/etc/netplan/99-nested-virt-lab.yaml" \
    --upload "${staging}/chpasswd_line:/tmp/nested-virt-chpasswd" \
    --upload "${auth_keys}:/tmp/nested-virt-authorized-keys" \
    --run-command 'chmod 600 /etc/netplan/99-nested-virt-lab.yaml' \
    --run-command 'id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm ubuntu' \
    --run-command 'install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh' \
    --run-command 'install -m 600 -o ubuntu -g ubuntu /tmp/nested-virt-authorized-keys /home/ubuntu/.ssh/authorized_keys' \
    --run-command 'install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu' \
    --run-command 'chpasswd -e < /tmp/nested-virt-chpasswd' \
    --run-command 'passwd -u ubuntu 2>/dev/null || true' \
    --run-command 'mkdir -p /etc/ssh/sshd_config.d /etc/sudoers.d' \
    --run-command 'rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf /tmp/nested-virt-chpasswd /tmp/nested-virt-authorized-keys' \
    --run-command 'printf "%s\n" "PasswordAuthentication yes" "KbdInteractiveAuthentication yes" "PubkeyAuthentication yes" > /etc/ssh/sshd_config.d/99-nested-virt-password.conf' \
    --run-command 'echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-nested-virt-ubuntu && chmod 440 /etc/sudoers.d/99-nested-virt-ubuntu' \
    --run-command 'touch /etc/cloud/cloud-init.disabled' \
    --install openssh-server \
    --run-command 'ssh-keygen -A' \
    --run-command 'systemctl enable ssh' \
    --install curl \
    --run-command 'cloud-init clean --logs --seed 2>/dev/null || true'
  rm -f "$netplan"
  rm -rf "$staging"
  log "virt-customize netplan+credentials ip=${INNER_IP} mac=${INNER_MAC}"
}

update_lab_dhcp() {
  local conf=/etc/nested-virt-dnsmasq.conf
  [[ -f "$conf" ]] || return 0
  if grep -q "${INNER_MAC}" "$conf" 2>/dev/null; then
    log "dnsmasq already has ${INNER_MAC}"
    return 0
  fi
  cat >> "$conf" <<EOF
dhcp-host=${INNER_MAC},${INNER_IP},set:inner-${SITE_ID},infinite
dhcp-option=tag:inner-${SITE_ID},3,${GATEWAY}
EOF
  pkill -HUP -f "${conf}" 2>/dev/null || true
  log "dnsmasq reservation ${INNER_MAC} -> ${INNER_IP}"
}

main() {
  ensure_tools
  mkdir -p "$SERVE_DIR"
  if [[ -n "${INNER_SSH_PASS:-}" ]]; then
    INNER_LAB_PASS="$INNER_SSH_PASS"
    umask 077
    printf '%s' "$INNER_LAB_PASS" > "$INNER_PASS_FILE"
    chmod 600 "$INNER_PASS_FILE"
    log "using INNER_SSH_PASS override → ${INNER_PASS_FILE}"
  else
    generate_inner_ssh_password
  fi
  ensure_inner_ssh_key
  fetch_and_convert_base
  cp -f "$BASE_VHDX" "$VHDX_OUT"
  inject_netplan
  [[ -f "${PS1_SRC:-}" ]] && cp -f "$PS1_SRC" "${SERVE_DIR}/provision-ubuntu-inner-vm.ps1"
  build_seed_iso
  update_lab_dhcp
  log "ready serve_dir=${SERVE_DIR} vhdx=${VHDX_OUT} seed=${SEED_OUT}"
  sha256sum "$VHDX_OUT" | awk '{print $1}' > "${SERVE_DIR}/ubuntu-inner.vhdx.sha256"
  log "vhdx sha256=$(cat "${SERVE_DIR}/ubuntu-inner.vhdx.sha256")"
}

main "$@"
