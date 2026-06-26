#!/usr/bin/env bash
# Upload guest provisioning scripts and run on both nested-virt metal hosts.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${BIN}/.." && pwd)"
source "${ROOT}/config.env"
[[ -f "${ROOT}/config.local.env" ]] && source "${ROOT}/config.local.env"
[[ -f "${ROOT}/sites.env" ]] || { echo "Missing sites.env — deploy sites and run configure-peer-routing.sh"; exit 1; }
# shellcheck source=/dev/null
source "${ROOT}/sites.env"

: "${SITE_0_INSTANCE_ID:?}"
: "${SITE_1_INSTANCE_ID:?}"
: "${KEY_NAME:?Set KEY_NAME in config.local.env}"

BOOTSTRAP_BUCKET="${BOOTSTRAP_BUCKET:-nested-virt-bootstrap-${AWS_ACCOUNT_ID}}"
WINDOWS_ISO_S3_URI="${WINDOWS_ISO_S3_URI:-}"
S3_PREFIX="s3://${BOOTSTRAP_BUCKET}/nested-virt"

echo "=== Upload Hyper-V guest scripts ==="
aws s3 cp "${ROOT}/scripts/provision-windows-guest.sh" "${S3_PREFIX}/provision-windows-guest.sh" --region "$AWS_REGION"
aws s3 cp "${ROOT}/scripts/autounattend.xml" "${S3_PREFIX}/autounattend.xml" --region "$AWS_REGION"
aws s3 cp "${ROOT}/scripts/enable-hyperv.ps1" "${S3_PREFIX}/enable-hyperv.ps1" --region "$AWS_REGION"

run_on_instance() {
  local iid="$1" label="$2"
  echo "--- ${label} (${iid}) ---"
  local env_prefix=""
  if [[ -n "$WINDOWS_ISO_S3_URI" ]]; then
    env_prefix="WINDOWS_ISO_S3_URI=${WINDOWS_ISO_S3_URI}"
  fi
  if [[ "${FORCE_REINSTALL:-0}" == "1" ]]; then
    env_prefix="${env_prefix} FORCE_REINSTALL=1"
  fi
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$iid" \
    --document-name AWS-RunShellScript \
    --timeout-seconds 7200 \
    --parameters "commands=[\"aws s3 cp ${S3_PREFIX}/provision-windows-guest.sh /tmp/provision-windows-guest.sh && aws s3 cp ${S3_PREFIX}/autounattend.xml /tmp/autounattend.xml && aws s3 cp ${S3_PREFIX}/enable-hyperv.ps1 /tmp/enable-hyperv.ps1 && chmod +x /tmp/provision-windows-guest.sh && nohup env UNATTEND_TEMPLATE=/tmp/autounattend.xml ENABLE_HYPERV_PS1=/tmp/enable-hyperv.ps1 ${env_prefix} /tmp/provision-windows-guest.sh > /var/log/nested-virt-provision.log 2>&1 & echo started\"]" \
    --query Command.CommandId --output text)
  sleep 15
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
  echo "(Provisioning continues in background — tail /var/log/nested-virt-provision.log on host)"
}

run_on_instance "$SITE_0_INSTANCE_ID" "Site 0"
run_on_instance "$SITE_1_INSTANCE_ID" "Site 1"

echo ""
echo "Next: if prep-only (no ISO), copy Windows Server 2022 ISO to S3 and re-run:"
echo "  WINDOWS_ISO_S3_URI=s3://your-bucket/Win2022.iso ./bin/deploy-hyperv-guest.sh"
echo ""
echo "VNC to guest install (via SSH tunnel to metal host public IP):"
echo "  ssh -L 5900:127.0.0.1:5900 -i ~/.ssh/${KEY_NAME}.pem ubuntu@<metal-public-ip>"
echo "Guest admin password on host: /var/lib/nested-virt/win-guest-admin-password"
