#!/usr/bin/env bash
# Upload all host-side lab scripts to the bootstrap S3 prefix (idempotent).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

BOOTSTRAP_BUCKET="${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}"
S3_PREFIX="s3://${BOOTSTRAP_BUCKET}/nested-virt"
REGION="${AWS_REGION:-us-east-1}"

SCRIPTS=(
  bootstrap.sh:bootstrap.sh
  scripts/ensure-lab-dnsmasq.sh
  scripts/ensure-lab-vnc.sh
  scripts/ensure-lab-image-cache.sh
  scripts/ensure-lab-guest-dns.ps1
  scripts/ensure-inner-guest-dns.sh
  scripts/internet-proof-on-host.sh
  scripts/apply-peer-routes.sh
  scripts/fix-transport-routing.sh
  scripts/setup-gre-tunnel.sh
  scripts/provision-windows-guest.sh
  scripts/autounattend.xml
  scripts/enable-hyperv.ps1
  scripts/enable-hyperv-nested-host.ps1
  scripts/fix-kvm-nested-hyperv-xml.sh
  scripts/prepare-ubuntu-inner-image.sh
  scripts/provision-ubuntu-inner-vm.ps1
  scripts/deploy-inner-ubuntu-on-host.sh
  scripts/deploy-real-l2.sh
  scripts/open-guest-firewall.ps1
  scripts/apply-guest-firewall.sh
)

if ! aws s3api head-bucket --bucket "${BOOTSTRAP_BUCKET}" >/dev/null 2>&1; then
  if [[ "${REGION}" != "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BOOTSTRAP_BUCKET}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" 2>/dev/null || true
  else
    aws s3api create-bucket --bucket "${BOOTSTRAP_BUCKET}" --region "${REGION}" 2>/dev/null || true
  fi
fi

echo "=== Upload lab scripts → ${S3_PREFIX} ==="
for entry in "${SCRIPTS[@]}"; do
  src="${entry%%:*}"
  dst="${entry##*:}"
  [[ "$entry" == "$src" ]] && dst="$(basename "$src")"
  aws s3 cp "${ROOT}/${src}" "${S3_PREFIX}/${dst}" --region "${REGION}"
done
echo "Upload complete."
