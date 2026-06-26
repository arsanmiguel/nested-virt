#!/usr/bin/env bash
# Deploy Ubuntu 24.04 inner VMs on both sites via Hyper-V (real L2: KVM → Hyper-V → Ubuntu).
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

SCRIPTS=(
  fix-kvm-nested-hyperv-xml.sh
  enable-hyperv-nested-host.ps1
  prepare-ubuntu-inner-image.sh
  provision-ubuntu-inner-vm.ps1
  deploy-inner-ubuntu-on-host.sh
  deploy-real-l2.sh
)

echo "=== Upload Hyper-V L2 scripts ==="
for s in "${SCRIPTS[@]}"; do
  aws s3 cp "${ROOT}/scripts/${s}" "${S3_PREFIX}/${s}" --region "$AWS_REGION"
done

run_on_instance() {
  local iid="$1" site_id="$2" label="$3"
  echo "--- ${label} site ${site_id} (${iid}) ---"
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 7200 \
    --parameters "commands=[\"aws s3 cp ${S3_PREFIX}/fix-kvm-nested-hyperv-xml.sh /tmp/fix-kvm-nested-hyperv-xml.sh && aws s3 cp ${S3_PREFIX}/enable-hyperv-nested-host.ps1 /tmp/enable-hyperv-nested-host.ps1 && aws s3 cp ${S3_PREFIX}/prepare-ubuntu-inner-image.sh /tmp/prepare-ubuntu-inner-image.sh && aws s3 cp ${S3_PREFIX}/provision-ubuntu-inner-vm.ps1 /tmp/provision-ubuntu-inner-vm.ps1 && aws s3 cp ${S3_PREFIX}/deploy-inner-ubuntu-on-host.sh /tmp/deploy-inner-ubuntu-on-host.sh && aws s3 cp ${S3_PREFIX}/deploy-real-l2.sh /tmp/deploy-real-l2.sh && chmod +x /tmp/*.sh && nohup /tmp/deploy-real-l2.sh ${site_id} >> /var/log/nested-virt-inner-deploy.log 2>&1 & echo started\"]" \
    --query Command.CommandId --output text)
  sleep 15
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
  echo "(Deploy continues in background — tail /var/log/nested-virt-inner-deploy.log)"
}

run_on_instance "$SITE_0_INSTANCE_ID" 0 "Site 0"
run_on_instance "$SITE_1_INSTANCE_ID" 1 "Site 1"

echo ""
echo "Real L2 path: metal KVM → Windows Hyper-V guest → Ubuntu inner @ 10.x.1.20"
echo "Poll: ./bin/invoke-routing-proof.sh --layer l2"
echo "Verify vmms: WinRM sc.exe query vmms inside Windows guest"
echo "Hiccups doc: docs/nested-virt-hiccups.md"
