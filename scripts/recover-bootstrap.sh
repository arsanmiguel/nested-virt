#!/usr/bin/env bash
# Recover stalled bootstrap: rename NICs via IMDS, fix transport routing, resume bootstrap.
set -euo pipefail

log() { echo "$(date -Iseconds) RECOVER $*"; }

imds_token() {
  curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60"
}

rename_nics() {
  local token mac devno cur name sysfs_mac
  token="$(imds_token)"
  mapfile -t macs < <(curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/network/interfaces/macs/" | tr -d '/')
  for mac in "${macs[@]}"; do
    devno=$(curl -sf -H "X-aws-ec2-metadata-token: ${token}" \
      "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${mac}/device-number")
    cur=""
    for iface in /sys/class/net/*; do
      [[ -f "${iface}/address" ]] || continue
      sysfs_mac=$(tr '[:upper:]' '[:lower:]' < "${iface}/address")
      if [[ "$sysfs_mac" == "${mac,,}" ]]; then
        cur=$(basename "$iface")
        break
      fi
    done
    [[ -z "$cur" ]] && { log "no iface for mac=${mac}"; continue; }
    name="kvm-host-nic${devno}"
    if [[ "$cur" != "$name" ]]; then
      ip link set "$cur" down || true
      if ip link set "$cur" name "$name"; then
        log "renamed ${cur} -> ${name}"
      else
        log "rename failed ${cur} -> ${name}"
      fi
      ip link set "$name" up || true
    else
      log "already ${name}"
    fi
  done
}

rename_nics
ip -br a | grep -E 'kvm-host|enP' || true

account=$(curl -sf -H "X-aws-ec2-metadata-token: $(imds_token)" \
  http://169.254.169.254/latest/dynamic/instance-identity/document | \
  sed -n 's/.*"accountId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
region=$(curl -sf -H "X-aws-ec2-metadata-token: $(imds_token)" \
  http://169.254.169.254/latest/meta-data/placement/region)

aws s3 cp "s3://nested-virt-bootstrap-${account}/nested-virt/fix-transport-routing.sh" \
  /tmp/fix-transport-routing.sh --region "$region"
chmod +x /tmp/fix-transport-routing.sh
/tmp/fix-transport-routing.sh || true

phase="$(tr -d '[:space:]' < /var/lib/nested-virt/bootstrap-phase 2>/dev/null || echo nested)"
log "phase=${phase}"

if pgrep -f '/var/lib/nested-virt/bootstrap.sh' >/dev/null; then
  log "bootstrap already running"
  exit 0
fi

nohup /var/lib/nested-virt/bootstrap.sh >> /var/log/amazon/launch-timing.log 2>&1 &
log "bootstrap restarted pid=$!"

aws s3 cp "s3://nested-virt-bootstrap-${account}/nested-virt/ensure-lab-dnsmasq.sh" \
  /tmp/ensure-lab-dnsmasq.sh --region "$region" 2>/dev/null && \
  source /tmp/ensure-lab-dnsmasq.sh && harden_metal_dns && verify_no_public_dns || \
  log "dns harden skipped or failed"
