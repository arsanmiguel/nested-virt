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
UNATTEND_ISO="${IMAGES}/autounattend.iso"
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
  apt-get install -y genisoimage wget curl qemu-utils
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

build_unattend_iso() {
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
  genisoimage -quiet -o "$UNATTEND_ISO" -J -r "${staging}"
  rm -rf "$staging"
  log "unattend iso site_id=${site_id} guest_ip=${guest_ip} gateway=${gateway}"
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
  if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    log "vm ${VM_NAME} already defined state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo unknown)"
    return 0
  fi
  local site_id site_oct
  site_id=$(imds_tag SiteId); site_id="${site_id:-0}"
  site_oct="$site_id"
  build_unattend_iso "$site_id"

  log "virt-install begin vm=${VM_NAME} bridge=br-default site=${site_id}"
  virt-install \
    --name "$VM_NAME" \
    --memory 32768 \
    --vcpus 8 \
    --cpu host-passthrough \
    --disk path="$DISK",bus=virtio,format=qcow2 \
    --disk path="$WIN_ISO",device=cdrom \
    --disk path="$VIRTIO_ISO",device=cdrom \
    --disk path="$UNATTEND_ISO",device=cdrom \
    --network bridge="br-default",model=virtio \
    --os-variant win2k22 \
    --graphics vnc,listen=0.0.0.0,port=5900 \
    --noautoconsole \
    --boot uefi,hd,cdrom \
    --channel unix,target_type=virtio,name=org.qemu.guest_agent_0 \
    --memballoon virtio \
    --rng /dev/urandom
  log "virt-install submitted vm=${VM_NAME} vnc=0.0.0.0:5900 guest_ip=10.${site_oct}.1.10"
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
      log "already complete vm=${VM_NAME} state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo n/a)"
      ;;
    *)
      log "unknown phase=${phase}"; exit 1 ;;
  esac
}

main "$@"
