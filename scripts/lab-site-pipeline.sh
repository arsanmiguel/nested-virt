#!/usr/bin/env bash
# On-metal lab pipeline after bootstrap — pulls all steps from S3 (no laptop repo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=s3-lab-common.sh
source "${SCRIPT_DIR}/s3-lab-common.sh"

PHASE_FILE="${LAB_STATE_DIR}/lab-pipeline-phase"
SITE_ID="$(lab_site_id)"
S3_PREFIX="$(lab_s3_prefix)"
REGION="$(lab_region)"

get_phase() { cat "$PHASE_FILE" 2>/dev/null || echo start; }
set_phase() { echo "$1" > "$PHASE_FILE"; lab_log "pipeline phase=$1"; }

run_lab_security_verify() {
  s3_fetch_script ensure-lab-dnsmasq.sh /tmp/ensure-lab-dnsmasq.sh
  s3_fetch_script ensure-lab-vnc.sh /tmp/ensure-lab-vnc.sh
  # shellcheck source=/dev/null
  source /tmp/ensure-lab-dnsmasq.sh
  harden_metal_dns || true
  verify_no_public_dns || return 1
  # shellcheck source=/dev/null
  source /tmp/ensure-lab-vnc.sh
  harden_metal_vnc || true
  verify_no_public_vnc || return 1
  lab_log "lab security verify OK site=${SITE_ID}"
}

run_windows_guest() {
  s3_fetch_script provision-windows-guest.sh /tmp/provision-windows-guest.sh
  s3_fetch_script ensure-lab-dnsmasq.sh /tmp/ensure-lab-dnsmasq.sh
  s3_fetch_script ensure-lab-image-cache.sh /tmp/ensure-lab-image-cache.sh
  aws s3 cp "${S3_PREFIX}/autounattend.xml" /tmp/autounattend.xml --region "$REGION"
  aws s3 cp "${S3_PREFIX}/enable-hyperv.ps1" /tmp/enable-hyperv.ps1 --region "$REGION"
  nohup env UNATTEND_TEMPLATE=/tmp/autounattend.xml ENABLE_HYPERV_PS1=/tmp/enable-hyperv.ps1 \
    /tmp/provision-windows-guest.sh >> /var/log/nested-virt-provision.log 2>&1 &
  lab_log "windows guest provisioning started site=${SITE_ID}"
}

wait_guest() {
  local ip="10.${SITE_ID}.1.10" attempt
  for attempt in $(seq 1 90); do
    ping -c1 -W3 "$ip" >/dev/null 2>&1 && { lab_log "guest up ${ip}"; return 0; }
    sleep 60
  done
  return 1
}

run_guest_firewall() {
  s3_fetch_script apply-guest-firewall.sh /tmp/apply-guest-firewall.sh
  aws s3 cp "${S3_PREFIX}/open-guest-firewall.ps1" /tmp/open-guest-firewall.ps1 --region "$REGION"
  GUEST_IP="10.${SITE_ID}.1.10" PASS_FILE="${LAB_STATE_DIR}/win-guest-admin-password" \
    /tmp/apply-guest-firewall.sh || lab_log "guest firewall warn site=${SITE_ID}"
}

run_l2() {
  s3_fetch_script deploy-real-l2.sh /tmp/deploy-real-l2.sh
  s3_fetch_script fix-kvm-nested-hyperv-xml.sh /tmp/fix-kvm-nested-hyperv-xml.sh
  s3_fetch_script deploy-inner-ubuntu-on-host.sh /tmp/deploy-inner-ubuntu-on-host.sh
  s3_fetch_script prepare-ubuntu-inner-image.sh /tmp/prepare-ubuntu-inner-image.sh
  s3_fetch_script provision-ubuntu-inner-vm.ps1 /tmp/provision-ubuntu-inner-vm.ps1
  s3_fetch_script ensure-inner-guest-dns.sh /tmp/ensure-inner-guest-dns.sh
  aws s3 cp "${S3_PREFIX}/enable-hyperv-nested-host.ps1" /tmp/enable-hyperv-nested-host.ps1 --region "$REGION"
  aws s3 cp "${S3_PREFIX}/ensure-lab-guest-dns.ps1" /tmp/ensure-lab-guest-dns.ps1 --region "$REGION"
  SITE_ID="$SITE_ID" /tmp/deploy-real-l2.sh "$SITE_ID"
}

wait_l2() {
  local ip="10.${SITE_ID}.1.20" attempt
  for attempt in $(seq 1 120); do
    ping -c1 -W3 "$ip" >/dev/null 2>&1 && { lab_log "l2 up ${ip}"; return 0; }
    sleep 90
  done
  return 1
}

run_inner_internet() {
  s3_fetch_script ensure-inner-guest-dns.sh /tmp/ensure-inner-guest-dns.sh
  s3_fetch_script ensure-lab-guest-dns.ps1 /tmp/ensure-lab-guest-dns.ps1
  REFRESH_INNER_VHDX=0 /tmp/ensure-inner-guest-dns.sh "$SITE_ID" || return 1
}

run_proofs() {
  s3_fetch_script lab-verification.sh /tmp/lab-verification.sh
  /tmp/lab-verification.sh --record || return 1
  if [[ "$SITE_ID" == "0" ]]; then
    /tmp/lab-verification.sh --aggregate-lab || return 1
  fi
}

main() {
  mkdir -p "$LAB_STATE_DIR" /var/log/amazon
  lab_log "pipeline START site=${SITE_ID} phase=$(get_phase)"

  local phase
  phase="$(get_phase)"
  while [[ "$phase" != complete ]]; do
    case "$phase" in
      start)
        if [[ "$SITE_ID" == "0" ]]; then
          s3_fetch_script coordinate-peer-routing-on-host.sh /tmp/coordinate-peer-routing-on-host.sh
          /tmp/coordinate-peer-routing-on-host.sh || exit 1
        else
          # Wait for coordinator to tag peers and replicate sites.env.
          for _ in $(seq 1 60); do
            if [[ -f "${LAB_STATE_DIR}/sites.env" ]] && imds_tag PeerTransportEniIp | grep -q .; then break; fi
            sleep 30
          done
        fi
        set_phase security
        ;;
      security)
        run_lab_security_verify || exit 1
        set_phase guest
        ;;
      guest)
        run_windows_guest
        wait_guest || exit 1
        set_phase firewall
        ;;
      firewall)
        run_guest_firewall
        set_phase l2
        ;;
      l2)
        run_l2
        wait_l2 || exit 1
        set_phase internet
        ;;
      internet)
        run_inner_internet || exit 1
        set_phase proofs
        ;;
      proofs)
        run_proofs || exit 1
        set_phase complete
        ;;
      complete)
        lab_log "pipeline already complete site=${SITE_ID}"
        exit 0
        ;;
      *)
        lab_log "pipeline unknown phase=${phase}"
        exit 1
        ;;
    esac
    phase="$(get_phase)"
  done
  lab_log "pipeline COMPLETE site=${SITE_ID}"
}

main "$@"
