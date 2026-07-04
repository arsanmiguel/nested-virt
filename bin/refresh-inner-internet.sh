#!/usr/bin/env bash
# Re-download inner VHDX (with public DNS + SSH password baked in) on both sites. ~45–90 min each.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"
[[ -f "${ROOT}/sites.env" ]] || { echo "Missing sites.env"; exit 1; }
# shellcheck source=/dev/null
source "${ROOT}/sites.env"

BOOTSTRAP_BUCKET="${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}"
S3_PREFIX="s3://${BOOTSTRAP_BUCKET}/nested-virt"

for s in ensure-inner-guest-dns.sh prepare-ubuntu-inner-image.sh provision-ubuntu-inner-vm.ps1 deploy-inner-ubuntu-on-host.sh ensure-lab-guest-dns.ps1; do
  aws s3 cp "${ROOT}/scripts/${s}" "${S3_PREFIX}/${s}" --region "$AWS_REGION"
done

run_refresh() {
  local iid="$1" site_id="$2"
  echo "--- Refresh inner site ${site_id} (${iid}) — background ---"
  aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 7200 \
    --parameters "commands=[\"aws s3 cp ${S3_PREFIX}/ensure-inner-guest-dns.sh /tmp/ensure-inner-guest-dns.sh && aws s3 cp ${S3_PREFIX}/prepare-ubuntu-inner-image.sh /tmp/prepare-ubuntu-inner-image.sh && aws s3 cp ${S3_PREFIX}/provision-ubuntu-inner-vm.ps1 /tmp/provision-ubuntu-inner-vm.ps1 && aws s3 cp ${S3_PREFIX}/deploy-inner-ubuntu-on-host.sh /tmp/deploy-inner-ubuntu-on-host.sh && aws s3 cp ${S3_PREFIX}/ensure-lab-guest-dns.ps1 /tmp/ensure-lab-guest-dns.ps1 && chmod +x /tmp/ensure-inner-guest-dns.sh /tmp/prepare-ubuntu-inner-image.sh /tmp/deploy-inner-ubuntu-on-host.sh && pkill -f deploy-inner-ubuntu-on-host.sh 2>/dev/null || true; rm -f /var/lib/nested-virt/inner-deploy.lock; nohup env REFRESH_INNER_VHDX=1 SITE_ID=${site_id} /tmp/ensure-inner-guest-dns.sh ${site_id} >> /var/log/nested-virt-inner-refresh.log 2>&1 & echo refresh_started\"]" \
    --query Command.CommandId --output text
}

run_refresh "$SITE_0_INSTANCE_ID" 0
sleep 30
run_refresh "$SITE_1_INSTANCE_ID" 1
echo "Poll: tail /var/log/nested-virt-inner-refresh.log on metal hosts, then ./bin/invoke-routing-proof.sh --layer internet"
