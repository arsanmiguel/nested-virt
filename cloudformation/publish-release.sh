#!/usr/bin/env bash
# Publish nested-virt release to S3 (CI / maintainer). Lab operators never run this.
# After publish, deploy with cloudformation/lab-root.yaml via TemplateURL only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFN="${ROOT}/cloudformation"
source "${ROOT}/config.env" 2>/dev/null || true
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
BOOTSTRAP_BUCKET="${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}"
S3_PREFIX="s3://${BOOTSTRAP_BUCKET}/nested-virt"
RELEASE_ID="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"

export BOOTSTRAP_BUCKET AWS_ACCOUNT_ID AWS_REGION
echo "=== Publish nested-virt release ${RELEASE_ID} → ${S3_PREFIX} ==="

if ! aws s3api head-bucket --bucket "${BOOTSTRAP_BUCKET}" >/dev/null 2>&1; then
  if [[ "${AWS_REGION}" != "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BOOTSTRAP_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  else
    aws s3api create-bucket --bucket "${BOOTSTRAP_BUCKET}" --region "${AWS_REGION}"
  fi
fi

echo "${BOOTSTRAP_BUCKET}" > "${CFN}/.bootstrap-bucket.env"

# Package per-site template (UserData stub + bucket name).
python3 "${CFN}/package-template.py"
cp "${CFN}/packaged-template.yaml" "${CFN}/packaged-site.yaml"

# Runtime scripts (instances pull these; not the operator laptop).
RUNTIME_FILES=(
  bootstrap.sh
  userdata-stub.sh
  scripts/s3-lab-common.sh
  scripts/coordinate-peer-routing-on-host.sh
  scripts/lab-site-pipeline.sh
  scripts/routing-proof-on-host.sh
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

echo "=== Upload runtime scripts ==="
for rel in "${RUNTIME_FILES[@]}"; do
  base="$(basename "$rel")"
  aws s3 cp "${ROOT}/${rel}" "${S3_PREFIX}/${base}" --region "${AWS_REGION}"
done

echo "=== Upload CloudFormation templates ==="
aws s3 cp "${CFN}/packaged-site.yaml" "${S3_PREFIX}/cloudformation/packaged-site.yaml" --region "${AWS_REGION}"
aws s3 cp "${CFN}/lab-root.yaml" "${S3_PREFIX}/cloudformation/lab-root.yaml" --region "${AWS_REGION}"

MANIFEST="${CFN}/release-manifest.json"
cat > "$MANIFEST" <<EOF
{
  "releaseId": "${RELEASE_ID}",
  "publishedUtc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bootstrapBucket": "${BOOTSTRAP_BUCKET}",
  "region": "${AWS_REGION}",
  "labRootTemplateUrl": "https://${BOOTSTRAP_BUCKET}.s3.${AWS_REGION}.amazonaws.com/nested-virt/cloudformation/lab-root.yaml",
  "siteTemplateUrl": "https://${BOOTSTRAP_BUCKET}.s3.${AWS_REGION}.amazonaws.com/nested-virt/cloudformation/packaged-site.yaml",
  "s3Prefix": "${S3_PREFIX}/"
}
EOF
aws s3 cp "$MANIFEST" "${S3_PREFIX}/release-manifest.json" --region "${AWS_REGION}"

echo ""
echo "Publish complete."
echo "  Lab root template: https://${BOOTSTRAP_BUCKET}.s3.${AWS_REGION}.amazonaws.com/nested-virt/cloudformation/lab-root.yaml"
echo "  Manifest:          ${S3_PREFIX}/release-manifest.json"
echo ""
echo "Operator deploy (no repo checkout):"
echo "  aws cloudformation create-stack --stack-name nested-virt-lab \\"
echo "    --template-url https://${BOOTSTRAP_BUCKET}.s3.${AWS_REGION}.amazonaws.com/nested-virt/cloudformation/lab-root.yaml \\"
echo "    --capabilities CAPABILITY_NAMED_IAM \\"
echo "    --parameters ParameterKey=KeyName,ParameterValue=YOUR_KEY ..."
