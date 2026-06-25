#!/usr/bin/env bash
# Provision Windows Server KVM guest for nested Hyper-V (runs on metal host).
set -euo pipefail

TIMING_LOG=/var/log/amazon/launch-timing.log
STATE_DIR=/var/lib/nested-virt
PHASE_FILE="${STATE_DIR}/hyperv-guest-phase"
IMAGES=/var/lib/libvirt/images
VM_NAME="${VM_NAME:-win-hv-nested}"
WIN_ISO="${IMAGES}/Win2022.iso"
VIRTIO_ISO="${IMAGES}/virtio-win.iso"
DISK="${IMAGES}/${VM_NAME}.qcow2"
UNATTEND_FLOPPY="${IMAGES}/autounattend.img"
WINDOWS_ISO_S3_URI="${WINDOWS_ISO_S3_URI:-}"
VIRTIO_ISO_URL="${VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"

log() { echo "$(date -Iseconds) HYPERV_GUEST $*" | tee -a "$TIMING_LOG"; }

imds_token() {
  curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}
imds_tag() {
  curl -sf -H "X-aws-ec2-metadata-token: $(imds_token)" \
    "http://169.254.169.254/latest/meta-data/tags/instance/${1}" 2>/dev/null || true
}

get_phase() {
  [[ -f "$PHASE_FILE" ]] && tr -d '[:space:]' < "$PHASE_FILE" || echo init
}
set_phase() { echo -n "$1" > "$PHASE_FILE"; }

ensure_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dosfstools mtools wget curl qemu-utils dnsmasq
}

validate_host() {
  local nested kvm_mod
  if grep -q Intel /proc/cpuinfo; then kvm_mod=kvm_intel; else kvm_mod=kvm_amd; fi
  nested=$(cat "/sys/module/${kvm_mod}/parameters/nested" 2>/dev/null || echo unknown)
  if [[ "$nested" != "Y" && "$nested" != "1" ]]; then
    log "ERROR nested virt not enabled (${kvm_mod}.nested=${nested})"
    exit 1
  fi
  if ! virsh net-list --all 2>/dev/null | grep -q .; then true; fi
  log "host ok nested=${nested} bridges=$(ip -br link show type bridge | awk '{print $1}' | paste -sd,)"
}

fetch_virtio() {
  if [[ -f "$VIRTIO_ISO" ]]; then
    log "virtio iso exists size=$(stat -c%s "$VIRTIO_ISO")"
    return 0
  fi
  log "downloading virtio-win iso"
  wget -q -O "$VIRTIO_ISO" "$VIRTIO_ISO_URL"
  log "virtio iso ready size=$(stat -c%s "$VIRTIO_ISO")"
}

fetch_windows_iso() {
  if [[ -f "$WIN_ISO" ]]; then
    log "windows iso exists size=$(stat -c%s "$WIN_ISO")"
    return 0
  fi
  if [[ -z "$WINDOWS_ISO_S3_URI" ]]; then
    log "WARN no WINDOWS_ISO_S3_URI and ${WIN_ISO} missing — skip install"
    return 1
  fi
  log "downloading windows iso from ${WINDOWS_ISO_S3_URI}"
  aws s3 cp "$WINDOWS_ISO_S3_URI" "$WIN_ISO"
  log "windows iso ready size=$(stat -c%s "$WIN_ISO")"
}

build_unattend_floppy() {
  local site_id="${1:-0}" guest_ip="10.${site_id}.1.10" gateway="10.${site_id}.1.1"
  local admin_pw pass_file="${STATE_DIR}/win-guest-admin-password"
  if [[ -f "$pass_file" ]]; then
    admin_pw=$(tr -d '[:space:]' < "$pass_file")
  else
    admin_pw=$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)
    umask 077
    echo "$admin_pw" > "$pass_file"
    chmod 600 "$pass_file"
    log "generated admin password file ${pass_file}"
  fi
  local staging template
  template="${UNATTEND_TEMPLATE:-/tmp/autounattend.xml}"
  [[ -f "$template" ]] || template="${STATE_DIR}/autounattend.xml"
  [[ -f "$template" ]] || { log "ERROR autounattend template missing"; exit 1; }
  staging=$(mktemp -d)
  sed -e "s/SITEID/${site_id}/g" \
      -e "s/GUEST_IP/${guest_ip}/g" \
      -e "s/BR_GATEWAY/${gateway}/g" \
      -e "s/ADMIN_PASSWORD/${admin_pw}/g" \
      "$template" > "${staging}/autounattend.xml"
  rm -f "$UNATTEND_FLOPPY"
  mkfs.vfat -C "$UNATTEND_FLOPPY" 1440
  mcopy -i "$UNATTEND_FLOPPY" "${staging}/autounattend.xml" ::
  rm -rf "$staging"
  log "unattend floppy site_id=${site_id} guest_ip=${guest_ip} gateway=${gateway}"
}

destroy_vm() {
  if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    log "destroy vm=${VM_NAME}"
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
  fi
  if [[ "${FORCE_REINSTALL:-0}" == "1" && -f "$DISK" ]]; then
    log "remove disk ${DISK} for clean reinstall"
    rm -f "$DISK"
  fi
}

guest_mac_for_site() {
  local site_id="${1:-0}"
  printf '52:54:00:10:%02x:10' "$((10#${site_id}))"
}

setup_lab_dhcp() {
  local site_id="${1:-0}" guest_ip="${2}" gateway="${3}" mac="${4}"
  local conf=/etc/nested-virt-dnsmasq.conf
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y dnsmasq
  cat > "$conf" <<EOF
port=0
interface=br-default
bind-interfaces
dhcp-host=${mac},${guest_ip},set:nested-guest,infinite
dhcp-option=tag:nested-guest,3,${gateway}
dhcp-option=tag:nested-guest,6,${gateway}
EOF
  pkill -f "${conf}" 2>/dev/null || true
  nohup dnsmasq -C "$conf" --pid-file=/run/nested-virt-dnsmasq.pid \
    >> /var/log/nested-virt-provision.log 2>&1 &
  ip link set br-default up 2>/dev/null || true
  log "lab dhcp site=${site_id} mac=${mac} ip=${guest_ip} gw=${gateway}"
}

start_cdrom_eject_watcher() {
  local site_id="${1:-0}" guest_ip="10.${site_id}.1.10"
  nohup bash -c "
    vm='${VM_NAME}'
    guest_ip='${guest_ip}'
    for _ in \$(seq 1 90); do
      sleep 60
      ping -c1 -W2 \"\$guest_ip\" >/dev/null 2>&1 && exit 0
      cpu1=\$(virsh dominfo \"\$vm\" 2>/dev/null | awk '/CPU time/ {print \$3}' | tr -d s)
      sleep 30
      cpu2=\$(virsh dominfo \"\$vm\" 2>/dev/null | awk '/CPU time/ {print \$3}' | tr -d s)
      if [[ -n \"\$cpu1\" && -n \"\$cpu2\" ]] && awk \"BEGIN{exit !(\$cpu2 - \$cpu1 < 2)}\"; then
        virsh domblklist \"\$vm\" --details 2>/dev/null | awk '/cdrom/ {print \$1}' | while read -r d; do
          virsh change-media \"\$vm\" \"\$d\" --eject --config 2>/dev/null || true
        done
      fi
    done
  " >> /var/log/nested-virt-provision.log 2>&1 &
  log "cdrom eject watcher started guest_ip=${guest_ip}"
}

create_disk() {
  if [[ -f "$DISK" ]]; then
    log "disk exists ${DISK}"
    return 0
  fi
  qemu-img create -f qcow2 "$DISK" 200G
  log "created disk ${DISK}"
}

start_install() {
  if [[ "${FORCE_REINSTALL:-0}" == "1" ]]; then
    destroy_vm
    create_disk
  elif virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    log "vm ${VM_NAME} already defined state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
    return 0
  fi
  local site_id guest_ip gateway guest_mac
  site_id=$(imds_tag SiteId); site_id="${site_id:-0}"
  guest_ip="10.${site_id}.1.10"
  gateway="10.${site_id}.1.1"
  guest_mac="$(guest_mac_for_site "$site_id")"
  build_unattend_floppy "$site_id"
  setup_lab_dhcp "$site_id" "$guest_ip" "$gateway" "$guest_mac"

  log "virt-install begin vm=${VM_NAME} bridge=br-default site=${site_id} mac=${guest_mac} boot=bios"
  virt-install \
    --name "$VM_NAME" \
    --memory 32768 \
    --vcpus 8 \
    --cpu host-passthrough \
    --machine ubuntu-q35 \
    --disk path="$DISK",bus=sata,format=qcow2 \
    --disk path="$WIN_ISO",device=cdrom \
    --disk path="$VIRTIO_ISO",device=cdrom \
    --disk path="$UNATTEND_FLOPPY",device=floppy \
    --network bridge="br-default",model=e1000,mac="${guest_mac}" \
    --os-variant win2k22 \
    --graphics vnc,listen=0.0.0.0,port=5900 \
    --noautoconsole \
    --boot hd,cdrom,menu=off \
    --channel unix,target_type=virtio,name=org.qemu.guest_agent_0 \
    --memballoon virtio \
    --rng /dev/urandom
  start_cdrom_eject_watcher "$site_id"
  log "virt-install submitted vm=${VM_NAME} vnc=0.0.0.0:5900 guest_ip=${guest_ip}"
}

main() {
  mkdir -p "$STATE_DIR" "$IMAGES"
  local phase
  phase="$(get_phase)"
  log "begin phase=${phase} vm=${VM_NAME}"

  case "$phase" in
    init)
      ensure_tools
      validate_host
      fetch_virtio
      create_disk
      if ! fetch_windows_iso; then
        set_phase prep
        log "prep complete — upload Win2022.iso or set WINDOWS_ISO_S3_URI then re-run"
        exit 0
      fi
      set_phase install
      phase=install
      ;;
    prep)
      if [[ ! -f "$WIN_ISO" ]] && ! fetch_windows_iso; then
        log "still no windows iso at ${WIN_ISO}"
        exit 0
      fi
      set_phase install
      phase=install
      ;;
  esac

  phase="$(get_phase)"
  case "$phase" in
    install)
      start_install
      set_phase complete
      log "complete vm=${VM_NAME} admin_password_file=${STATE_DIR}/win-guest-admin-password"
      ;;
    complete)
      if [[ "${FORCE_REINSTALL:-0}" == "1" ]]; then
        start_install
        set_phase complete
        log "reinstall complete vm=${VM_NAME}"
      else
        log "already complete vm=${VM_NAME} state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo n/a)"
      fi
      ;;
    *)
      log "unknown phase=${phase}"; exit 1 ;;
  esac
}

main "$@"
